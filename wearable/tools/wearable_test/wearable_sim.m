// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// wearable_sim.m — macOS BLE peripheral that impersonates the KelvinLee/Wearable wearable
// so the phone app runs its REAL on-device pipeline (BLE audio -> device_bridge ->
// Gemma on-device -> POST /api/device/text), driven from the Mac.
//
// Objective-C + clang, packaged as WearableSim.app and launched via `open` (see
// build.sh / run.sh). macOS TCC only honors NSBluetoothAlwaysUsageDescription when
// CoreBluetooth runs inside a LaunchServices-registered .app bundle, so commands
// arrive over a local TCP control socket (127.0.0.1:8765) instead of stdin, and
// output is written to /tmp/wearable-sim.log. Drive it with wearable_ctl.py.

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>

#define KELVINLEE_SVC       @"19b10000-e8f2-537e-4f6c-d104768a1214"
#define AUDIO_CHAR    @"19b10001-e8f2-537e-4f6c-d104768a1214"   // notify
#define CODEC_CHAR    @"19b10002-e8f2-537e-4f6c-d104768a1214"   // read (1=linear16)
#define BATTERY_SVC   @"180F"
#define BATTERY_CHAR  @"2A19"
#define DEVINFO_SVC   @"180A"
#define MODEL_CHAR    @"2A24"
#define FW_CHAR       @"2A26"
#define HW_CHAR       @"2A27"
#define MFG_CHAR      @"2A29"
#define BTN_SVC       @"23ba7924-0000-1000-7450-346eac492e92"
#define BTN_CHAR      @"23ba7925-0000-1000-7450-346eac492e92"
#define WEARABLE_BTN_CHAR @"23ba7924-0000-1000-8000-00805f9b34fb"
#define AGENT_CMD_SVC @"cab1ab90-0000-1000-8000-00805f9b34fb"
#define AGENT_CMD_CHAR @"cab1ab97-0000-1000-8000-00805f9b34fb"

static const int FRAME_BYTES = 320;   // 160 samples * 2 bytes = 10 ms @ 16 kHz
static const int CONTROL_PORT = 8765;
#define LOG_PATH @"/tmp/wearable-sim.log"

static NSFileHandle *gLog = nil;
static void logmsg(NSString *s) {
    NSString *line = [s stringByAppendingString:@"\n"];
    fputs(line.UTF8String, stdout); fflush(stdout);
    @try { [gLog writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (__unused id e) {}
}

static NSData *readWavPCM16(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:[path stringByExpandingTildeInPath]];
    if (!d || d.length < 44) return nil;
    const uint8_t *b = d.bytes;
    if (memcmp(b, "RIFF", 4) != 0 || memcmp(b + 8, "WAVE", 4) != 0) return nil;
    NSUInteger i = 12;
    while (i + 8 <= d.length) {
        uint32_t size = b[i+4] | (b[i+5]<<8) | (b[i+6]<<16) | ((uint32_t)b[i+7]<<24);
        if (memcmp(b + i, "data", 4) == 0) {
            NSUInteger start = i + 8, end = MIN(start + size, d.length);
            return [d subdataWithRange:NSMakeRange(start, end - start)];
        }
        i += 8 + size + (size & 1);
    }
    return nil;
}

@interface Wearable : NSObject <CBPeripheralManagerDelegate>
@property(nonatomic, strong) NSString *name;
@property(nonatomic, strong) CBPeripheralManager *pm;
@property(nonatomic, strong) CBMutableCharacteristic *audioChar, *btnChar, *wearableBtnChar;
@property(nonatomic, strong) NSMutableArray<NSData *> *queue;
@property(nonatomic, strong) dispatch_queue_t bleq;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic) int servicesToAdd;
@property(nonatomic) uint16_t packetId;
@property(nonatomic) uint8_t frameIndex;
@property(nonatomic) BOOL ready;
@end

@implementation Wearable

- (instancetype)initWithName:(NSString *)name {
    if ((self = [super init])) {
        _name = name; _queue = [NSMutableArray array];
        _bleq = dispatch_queue_create("ble", DISPATCH_QUEUE_SERIAL);
        _pm = [[CBPeripheralManager alloc] initWithDelegate:self queue:_bleq];
    }
    return self;
}

- (CBMutableCharacteristic *)ro:(NSString *)uuid value:(NSData *)v {
    return [[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:uuid]
        properties:CBCharacteristicPropertyRead value:v permissions:CBAttributePermissionsReadable];
}
- (CBMutableCharacteristic *)notifyChar:(NSString *)uuid {
    return [[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:uuid]
        properties:CBCharacteristicPropertyNotify value:nil permissions:0];
}

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)p {
    if (p.state == CBManagerStatePoweredOn) [self buildGatt];
    else if (p.state == CBManagerStateUnauthorized) logmsg(@"[sim] ERROR: Bluetooth permission denied — grant it in System Settings > Privacy & Security > Bluetooth, then relaunch.");
    else if (p.state == CBManagerStatePoweredOff) logmsg(@"[sim] ERROR: Bluetooth is off.");
    else logmsg([NSString stringWithFormat:@"[sim] BLE state %ld", (long)p.state]);
}

- (void)buildGatt {
    self.audioChar = [self notifyChar:AUDIO_CHAR];
    self.btnChar = [self notifyChar:BTN_CHAR];
    self.wearableBtnChar = [self notifyChar:WEARABLE_BTN_CHAR];
    uint8_t one = 1, full = 100;
    CBMutableService *kelvinlee = [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:KELVINLEE_SVC] primary:YES];
    kelvinlee.characteristics = @[self.audioChar, [self ro:CODEC_CHAR value:[NSData dataWithBytes:&one length:1]]];
    CBMutableService *batt = [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:BATTERY_SVC] primary:YES];
    batt.characteristics = @[[self ro:BATTERY_CHAR value:[NSData dataWithBytes:&full length:1]]];
    CBMutableService *dev = [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:DEVINFO_SVC] primary:YES];
    dev.characteristics = @[
        [self ro:MODEL_CHAR value:[@"KelvinLeeSim" dataUsingEncoding:NSUTF8StringEncoding]],
        [self ro:FW_CHAR value:[@"2.0.0-sim" dataUsingEncoding:NSUTF8StringEncoding]],
        [self ro:HW_CHAR value:[@"mac-sim" dataUsingEncoding:NSUTF8StringEncoding]],
        [self ro:MFG_CHAR value:[@"Wearable" dataUsingEncoding:NSUTF8StringEncoding]]];
    CBMutableService *btn = [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:BTN_SVC] primary:YES];
    btn.characteristics = @[self.btnChar, self.wearableBtnChar];
    CBMutableService *agent = [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:AGENT_CMD_SVC] primary:YES];
    agent.characteristics = @[[[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:AGENT_CMD_CHAR]
        properties:(CBCharacteristicPropertyWrite | CBCharacteristicPropertyWriteWithoutResponse)
        value:nil permissions:CBAttributePermissionsWriteable]];
    self.servicesToAdd = 5;
    for (CBMutableService *s in @[kelvinlee, batt, dev, btn, agent]) [self.pm addService:s];
}

- (void)peripheralManager:(CBPeripheralManager *)p didAddService:(CBService *)service error:(NSError *)error {
    if (error) logmsg([NSString stringWithFormat:@"[sim] add service failed: %@", error.localizedDescription]);
    if (--self.servicesToAdd == 0) {
        [self.pm startAdvertising:@{ CBAdvertisementDataLocalNameKey: self.name,
            CBAdvertisementDataServiceUUIDsKey: @[[CBUUID UUIDWithString:KELVINLEE_SVC]] }];
        self.ready = YES;
        logmsg([NSString stringWithFormat:@"[sim] advertising '%@' (KelvinLee service %@). Connect to it from the phone.", self.name, KELVINLEE_SVC]);
    }
}

- (void)peripheralManager:(CBPeripheralManager *)p central:(CBCentral *)c
        didSubscribeToCharacteristic:(CBCharacteristic *)ch {
    logmsg([NSString stringWithFormat:@"[sim] phone subscribed to %@", ch.UUID.UUIDString]);
}

- (void)peripheralManager:(CBPeripheralManager *)p didReceiveWriteRequests:(NSArray<CBATTRequest *> *)reqs {
    for (CBATTRequest *r in reqs) {
        if ([r.characteristic.UUID isEqual:[CBUUID UUIDWithString:AGENT_CMD_CHAR]] && r.value.length) {
            const uint8_t *b = r.value.bytes;
            const char *op = b[0]==1?"led_color":b[0]==2?"led_pattern":b[0]==3?"haptic":b[0]==4?"status_query":"op";
            NSMutableString *m = [NSMutableString stringWithFormat:@"  <- LED/haptic command: %s", op];
            for (NSUInteger i=1;i<r.value.length;i++) [m appendFormat:@" 0x%02x", b[i]];
            logmsg(m);
        }
        [self.pm respondToRequest:r withResult:CBATTErrorSuccess];
    }
}

- (void)peripheralManagerIsReadyToUpdateSubscribers:(CBPeripheralManager *)p { [self pump]; }

- (void)enqueueWav:(NSString *)path {
    NSData *pcm = readWavPCM16(path);
    if (!pcm) { logmsg([NSString stringWithFormat:@"[sim] could not read 16-bit mono WAV: %@", path]); return; }
    NSMutableArray<NSData *> *frames = [NSMutableArray array];
    const uint8_t *b = pcm.bytes;
    for (NSUInteger i = 0; i < pcm.length; i += FRAME_BYTES) {
        NSUInteger end = MIN(i + FRAME_BYTES, pcm.length);
        NSMutableData *frame = [NSMutableData data];
        uint8_t hdr[3] = { (uint8_t)(self.packetId & 0xFF), (uint8_t)((self.packetId >> 8) & 0xFF), self.frameIndex };
        [frame appendBytes:hdr length:3]; [frame appendBytes:b + i length:end - i];
        [frames addObject:frame]; self.packetId++; self.frameIndex++;
    }
    logmsg([NSString stringWithFormat:@"[sim] streaming %lu frames (~%.1fs)...", (unsigned long)frames.count, frames.count * 0.01]);
    dispatch_async(self.bleq, ^{ [self.queue addObjectsFromArray:frames]; [self startTimer]; });
}

- (void)startTimer {
    if (self.timer) return;
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.bleq);
    dispatch_source_set_timer(self.timer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
    __weak Wearable *ws = self;
    dispatch_source_set_event_handler(self.timer, ^{ [ws tick]; });
    dispatch_resume(self.timer);
}
- (void)tick {
    if (self.queue.count == 0) {
        if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; logmsg(@"[sim] audio stream done"); }
        return;
    }
    if ([self.pm updateValue:self.queue.firstObject forCharacteristic:self.audioChar onSubscribedCentrals:nil])
        [self.queue removeObjectAtIndex:0];
}
- (void)pump {
    while (self.queue.count) {
        if ([self.pm updateValue:self.queue.firstObject forCharacteristic:self.audioChar onSubscribedCentrals:nil])
            [self.queue removeObjectAtIndex:0];
        else return;
    }
}
- (void)press:(NSString *)codeName {
    NSDictionary *codes = @{@"single": @1, @"double": @2, @"long": @3, @"agent": @6};
    NSNumber *code = codes[codeName];
    if (!code) { logmsg([NSString stringWithFormat:@"[sim] unknown button '%@'", codeName]); return; }
    dispatch_async(self.bleq, ^{
        uint8_t c = code.unsignedCharValue; NSData *d = [NSData dataWithBytes:&c length:1];
        [self.pm updateValue:d forCharacteristic:self.btnChar onSubscribedCentrals:nil];
        [self.pm updateValue:d forCharacteristic:self.wearableBtnChar onSubscribedCentrals:nil];
        logmsg([NSString stringWithFormat:@"[sim] button %@ (code %d) sent", codeName, c]);
    });
}

// Command dispatch from the control socket. Returns a short reply line.
- (NSString *)handle:(NSString *)line {
    NSArray<NSString *> *parts = [[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                                  componentsSeparatedByString:@" "];
    NSString *cmd = parts.count ? parts[0].lowercaseString : @"";
    NSString *arg = parts.count > 1 ? parts[1] : nil;
    if ([cmd isEqualToString:@"audio"] && arg) { [self enqueueWav:arg]; return @"ok streaming"; }
    if ([cmd isEqualToString:@"say"] && arg) {
        [self press:@"agent"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ [self enqueueWav:arg]; });
        return @"ok say";
    }
    if ([cmd isEqualToString:@"button"]) { [self press:(arg ?: @"agent")]; return @"ok button"; }
    if ([cmd isEqualToString:@"status"]) return self.ready ? @"advertising" : @"not-ready";
    if ([cmd isEqualToString:@"quit"]) { logmsg(@"[sim] quit"); exit(0); }
    return @"unknown command";
}
@end

static void runControlServer(Wearable *sim) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        int s = socket(AF_INET, SOCK_STREAM, 0);
        int yes = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET; addr.sin_port = htons(CONTROL_PORT); addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) { logmsg(@"[sim] control bind failed (port in use?)"); return; }
        listen(s, 4);
        logmsg([NSString stringWithFormat:@"[sim] control socket on 127.0.0.1:%d", CONTROL_PORT]);
        while (1) {
            int c = accept(s, NULL, NULL);
            if (c < 0) continue;
            char buf[4096]; NSMutableData *acc = [NSMutableData data]; ssize_t n;
            while ((n = read(c, buf, sizeof(buf))) > 0) {
                [acc appendBytes:buf length:n];
                NSString *all = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding];
                NSArray<NSString *> *lines = [all componentsSeparatedByString:@"\n"];
                for (NSUInteger i = 0; i + 1 < lines.count; i++) {
                    NSString *cmd = lines[i]; if (!cmd.length) continue;
                    NSString *reply = [[sim handle:cmd] stringByAppendingString:@"\n"];
                    write(c, reply.UTF8String, strlen(reply.UTF8String));
                }
                acc = [[lines.lastObject dataUsingEncoding:NSUTF8StringEncoding] mutableCopy] ?: [NSMutableData data];
            }
            close(c);
        }
    });
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createFileAtPath:LOG_PATH contents:nil attributes:nil];
        gLog = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
        NSString *name = @"KelvinLee";
        for (int i = 1; i < argc - 1; i++)
            if (strcmp(argv[i], "--name") == 0) name = [NSString stringWithUTF8String:argv[i + 1]];
        logmsg([NSString stringWithFormat:@"[sim] starting (name=%@); log at %@", name, LOG_PATH]);
        Wearable *sim = [[Wearable alloc] initWithName:name];
        runControlServer(sim);
        dispatch_main();
    }
    return 0;
}
