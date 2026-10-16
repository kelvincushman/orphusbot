/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#include "sdcard.h"

#include <ff.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/fs/fs.h>
#include <zephyr/fs/fs_sys.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/sys/check.h>

LOG_MODULE_REGISTER(sdcard, CONFIG_LOG_DEFAULT_LEVEL);

/*
 * Every FAT access in the firmware funnels through this file, from three
 * threads: the pusher (transport.c) appending capture blocks, the storage
 * thread (storage.c) reading blocks back for the phone, and the BLE RX thread
 * answering the storage read characteristic. FATFS is not reentrant here and
 * the path scratch buffers below are shared, so one file-wide mutex guards
 * both the filesystem calls and the cached metadata.
 *
 * Zephyr mutexes are recursive, so the internal callers that nest
 * (mount_sd_card -> create_file, clear_audio_directory -> delete_audio_file)
 * are safe.
 *
 * Lock order: transport.c takes write_sdcard_mutex first and then reaches in
 * here. Nothing in this file ever takes write_sdcard_mutex, so there is no
 * cycle. is_sd_on()/sd_on()/sd_off() deliberately stay lock-free -- they only
 * touch a single bool and the pusher polls is_sd_on() on every frame.
 */
static K_MUTEX_DEFINE(sd_mutex);

static FATFS fat_fs;

static struct fs_mount_t mount_point = {
    .type = FS_FATFS,
    .fs_data = &fat_fs,
};

/* dt_flags is uint16_t and only carries devicetree-sourced flags (active
 * level, bias). Runtime flags live above bit 16 and must be passed to
 * gpio_pin_configure_dt() instead -- see sd_on(). */
struct gpio_dt_spec sd_en_gpio_pin = {.port = DEVICE_DT_GET(DT_NODELABEL(gpio0)),
                                      .pin = 19,
                                      .dt_flags = 0};

/* Guarded by sd_mutex. Reached from other files only via the sd_*() accessors
 * at the bottom of this file. */
static uint8_t file_count = 0;
static uint32_t file_num_array[2];

#define MAX_PATH_LENGTH 32
static char current_full_path[MAX_PATH_LENGTH];
static char read_buffer[MAX_PATH_LENGTH];
static char write_buffer[MAX_PATH_LENGTH];

static const char *disk_mount_pt = "/SD:/";
static const char *audio_dir_path = "/SD:/audio";
static const char *info_file_path = "/SD:/info.txt";

bool sd_enabled = false;
static bool sd_mounted = false;

static int get_file_contents(struct fs_dir_t *zdp, struct fs_dirent *entry);
static int delete_audio_file(uint8_t num);

int mount_sd_card(void)
{
    sd_enabled = false;
    sd_mounted = false;

    // initialize the sd card enable pin (v2)
    if (gpio_is_ready_dt(&sd_en_gpio_pin)) {
        LOG_INF("SD Enable Pin ready");
    } else {
        LOG_ERR("Error setting up SD Enable Pin");
        return -1;
    }

    if (gpio_pin_configure_dt(&sd_en_gpio_pin, GPIO_OUTPUT_ACTIVE) < 0) {
        LOG_ERR("Error setting up SD Pin");
        return -1;
    }

    k_mutex_lock(&sd_mutex, K_FOREVER);

    // initialize the sd card
    const char *disk_pdrv = "SD";
    int err = disk_access_init(disk_pdrv);
    LOG_INF("disk_access_init: %d", err);
    if (err) { // reattempt
        k_msleep(1000);
        err = disk_access_init(disk_pdrv);
        if (err) {
            LOG_ERR("disk_access_init failed");
            k_mutex_unlock(&sd_mutex);
            return -1;
        }
    }

    mount_point.mnt_point = "/SD:";
    int res = fs_mount(&mount_point);
    if (res == FR_OK) {
        LOG_INF("SD card mounted successfully");
    } else {
        LOG_ERR("f_mount failed: %d", res);
        k_mutex_unlock(&sd_mutex);
        return -1;
    }

    res = fs_mkdir(audio_dir_path);
    if (res == FR_OK) {
        LOG_INF("audio directory created successfully");
        initialize_audio_file(1);
    } else if (res == FR_EXIST) {
        LOG_INF("audio directory already exists");
    } else {
        LOG_INF("audio directory creation failed: %d", res);
    }

    struct fs_dir_t audio_dir_entry;
    fs_dir_t_init(&audio_dir_entry);
    err = fs_opendir(&audio_dir_entry, audio_dir_path);
    if (err) {
        LOG_ERR("error while opening directory %d", err);
        k_mutex_unlock(&sd_mutex);
        return -1;
    }

    initialize_audio_file(1);

    /* Walk the directory purely for its side effect: it caches the size of each
     * audio file into file_num_array. The capture path only ever records into
     * a01.txt, so the count is then pinned to one file regardless of what is on
     * the card -- a card carrying older a02.txt.. files must not make the
     * storage protocol offer files the writer never appends to. */
    struct fs_dirent file_count_entry;
    int files_on_card = get_file_contents(&audio_dir_entry, &file_count_entry);
    fs_closedir(&audio_dir_entry);

    if (files_on_card < 0) {
        LOG_ERR("error getting file count");
        k_mutex_unlock(&sd_mutex);
        return -1;
    }
    LOG_INF("audio files on card: %d", files_on_card);

    file_count = 1;
    LOG_INF("file count: %d", file_count);

    res = move_write_pointer(file_count);
    if (res) {
        LOG_ERR("error while moving the write pointer");
        k_mutex_unlock(&sd_mutex);
        return -1;
    }

    res = move_read_pointer(file_count);
    if (res) {
        LOG_ERR("error while moving the reader pointer");
        k_mutex_unlock(&sd_mutex);
        return -1;
    }

    struct fs_dirent info_file_entry; // check if the info file exists. if not, generate new info file
    res = fs_stat(info_file_path, &info_file_entry);
    if (res) {
        res = create_file("info.txt");
        save_offset(0);
        LOG_INF("result of info.txt creation: %d", res);
    }

    sd_mounted = true;
    sd_enabled = true;

    k_mutex_unlock(&sd_mutex);
    return 0;
}

uint32_t get_file_size(uint8_t num)
{
    char *ptr = generate_new_audio_header(num);
    if (ptr == NULL) {
        return 0;
    }

    k_mutex_lock(&sd_mutex, K_FOREVER);
    snprintf(current_full_path, sizeof(current_full_path), "%s%s", disk_mount_pt, ptr);
    struct fs_dirent entry;
    int res = fs_stat(current_full_path, &entry);
    k_mutex_unlock(&sd_mutex);

    k_free(ptr);
    if (res) {
        LOG_ERR("invalid file in get file size");
        return 0;
    }
    return (uint32_t) entry.size;
}

int move_read_pointer(uint8_t num)
{
    char *read_ptr = generate_new_audio_header(num);
    if (read_ptr == NULL) {
        return -1;
    }

    k_mutex_lock(&sd_mutex, K_FOREVER);
    snprintf(read_buffer, sizeof(read_buffer), "%s%s", disk_mount_pt, read_ptr);
    struct fs_dirent entry;
    int res = fs_stat(read_buffer, &entry);
    k_mutex_unlock(&sd_mutex);

    k_free(read_ptr);
    if (res) {
        LOG_ERR("invalid file in move read ptr");
        return -1;
    }
    return 0;
}

int move_write_pointer(uint8_t num)
{
    char *write_ptr = generate_new_audio_header(num);
    if (write_ptr == NULL) {
        return -1;
    }

    k_mutex_lock(&sd_mutex, K_FOREVER);
    snprintf(write_buffer, sizeof(write_buffer), "%s%s", disk_mount_pt, write_ptr);
    struct fs_dirent entry;
    int res = fs_stat(write_buffer, &entry);
    k_mutex_unlock(&sd_mutex);

    k_free(write_ptr);
    if (res) {
        LOG_ERR("invalid file in move write pointer");
        return -1;
    }
    return 0;
}

int create_file(const char *file_path)
{
    struct fs_file_t data_file;
    fs_file_t_init(&data_file);

    k_mutex_lock(&sd_mutex, K_FOREVER);
    snprintf(current_full_path, sizeof(current_full_path), "%s%s", disk_mount_pt, file_path);
    int ret = fs_open(&data_file, current_full_path, FS_O_WRITE | FS_O_CREATE);
    if (ret == 0) {
        fs_close(&data_file);
    }
    k_mutex_unlock(&sd_mutex);

    if (ret) {
        LOG_ERR("File creation failed %d", ret);
        return -2;
    }
    return 0;
}

int read_audio_data(uint8_t *buf, int amount, int offset)
{
    struct fs_file_t read_file;
    fs_file_t_init(&read_file);

    k_mutex_lock(&sd_mutex, K_FOREVER);

    int rc = fs_open(&read_file, read_buffer, FS_O_READ | FS_O_RDWR);
    if (rc < 0) {
        LOG_ERR("read: open failed %d", rc);
        k_mutex_unlock(&sd_mutex);
        return rc;
    }

    rc = fs_seek(&read_file, offset, FS_SEEK_SET);
    if (rc < 0) {
        LOG_ERR("read: seek to %d failed %d", offset, rc);
    } else {
        rc = fs_read(&read_file, buf, amount);
        if (rc < 0) {
            LOG_ERR("read: read failed %d", rc);
        }
    }

    fs_close(&read_file);
    k_mutex_unlock(&sd_mutex);

    return rc;
}

int write_to_file(uint8_t *data, uint32_t length)
{
    struct fs_file_t write_file;
    fs_file_t_init(&write_file);

    k_mutex_lock(&sd_mutex, K_FOREVER);

    int rc = fs_open(&write_file, write_buffer, FS_O_WRITE | FS_O_APPEND);
    if (rc < 0) {
        LOG_ERR("write: open failed %d", rc);
        k_mutex_unlock(&sd_mutex);
        return rc;
    }

    rc = fs_write(&write_file, data, length);
    if (rc < 0) {
        LOG_ERR("write: write failed %d", rc);
    }

    fs_close(&write_file);
    k_mutex_unlock(&sd_mutex);

    return rc;
}

int initialize_audio_file(uint8_t num)
{
    char *header = generate_new_audio_header(num);
    if (header == NULL) {
        return -1;
    }
    /* create_file() first, k_free() after: the old order freed the path and
     * then handed the dangling pointer to create_file(). */
    int res = create_file(header);
    k_free(header);
    return res;
}

char *generate_new_audio_header(uint8_t num)
{
    if (num > 99)
        return NULL;
    char *ptr_ = k_malloc(14);
    if (ptr_ == NULL) {
        return NULL;
    }
    ptr_[0] = 'a';
    ptr_[1] = 'u';
    ptr_[2] = 'd';
    ptr_[3] = 'i';
    ptr_[4] = 'o';
    ptr_[5] = '/';
    ptr_[6] = 'a';
    ptr_[7] = 48 + (num / 10);
    ptr_[8] = 48 + (num % 10);
    ptr_[9] = '.';
    ptr_[10] = 't';
    ptr_[11] = 'x';
    ptr_[12] = 't';
    ptr_[13] = '\0';

    return ptr_;
}

/* Caches each audio file's size into file_num_array and returns how many files
 * were seen. Caller must hold sd_mutex. */
static int get_file_contents(struct fs_dir_t *zdp, struct fs_dirent *entry)
{
    int count = 0;

    while (count < (int) ARRAY_SIZE(file_num_array)) {
        if (zdp->mp->fs->readdir(zdp, entry)) {
            return count == 0 ? -1 : count;
        }
        if (entry->name[0] == 0) { // end of directory
            break;
        }
        file_num_array[count] = entry->size;
        LOG_INF("file numarray %d %u", count, file_num_array[count]);
        LOG_INF("file name is %s", entry->name);
        count++;
    }

    return count;
}

// we should clear instead of delete since we lose fifo structure
int clear_audio_file(uint8_t num)
{
    char *clear_header = generate_new_audio_header(num);
    if (clear_header == NULL) {
        return -1;
    }

    k_mutex_lock(&sd_mutex, K_FOREVER);
    snprintf(current_full_path, sizeof(current_full_path), "%s%s", disk_mount_pt, clear_header);
    int res = fs_unlink(current_full_path);
    k_mutex_unlock(&sd_mutex);
    k_free(clear_header);

    if (res) {
        LOG_ERR("error deleting file");
        return -1;
    }

    k_msleep(10);
    res = initialize_audio_file(num);
    if (res) {
        LOG_ERR("error creating file");
        return -1;
    }

    return 0;
}

static int delete_audio_file(uint8_t num)
{
    char *ptr = generate_new_audio_header(num);
    if (ptr == NULL) {
        return -1;
    }

    k_mutex_lock(&sd_mutex, K_FOREVER);
    snprintf(current_full_path, sizeof(current_full_path), "%s%s", disk_mount_pt, ptr);
    int res = fs_unlink(current_full_path);
    k_mutex_unlock(&sd_mutex);
    k_free(ptr);

    if (res) {
        LOG_ERR("error deleting file in delete");
        return -1;
    }

    return 0;
}

// the nuclear option.
int clear_audio_directory()
{
    k_mutex_lock(&sd_mutex, K_FOREVER);

    /* file_count is pinned to 1 at mount, so in the shipping configuration this
     * returns here and NUKE is a no-op -- DELETE (clear_audio_file) is what
     * actually empties the recording. Behaviour deliberately left as-is: the
     * phone and server are written against it. */
    if (file_count == 1) {
        k_mutex_unlock(&sd_mutex);
        return 0;
    }

    int res = 0;
    for (uint8_t i = file_count; i > 0; i--) {
        res = delete_audio_file(i);
        k_msleep(10);
        if (res) {
            LOG_ERR("error on %d", i);
            k_mutex_unlock(&sd_mutex);
            return -1;
        }
    }

    res = fs_unlink(audio_dir_path);
    if (res) {
        LOG_ERR("error deleting directory");
        k_mutex_unlock(&sd_mutex);
        return -1;
    }

    res = fs_mkdir(audio_dir_path);
    if (res) {
        LOG_ERR("failed to make directory");
        k_mutex_unlock(&sd_mutex);
        return -1;
    }

    res = create_file("audio/a01.txt");
    if (res) {
        LOG_ERR("failed to make new file in directory files");
        k_mutex_unlock(&sd_mutex);
        return -1;
    }

    LOG_INF("done with clearing");

    file_count = 1;
    res = move_write_pointer(1);

    k_mutex_unlock(&sd_mutex);
    return res;
}

int save_offset(uint32_t offset)
{
    uint8_t buf[4] = {offset & 0xFF, (offset >> 8) & 0xFF, (offset >> 16) & 0xFF, (offset >> 24) & 0xFF};

    struct fs_file_t write_file;
    fs_file_t_init(&write_file);

    k_mutex_lock(&sd_mutex, K_FOREVER);

    int res = fs_open(&write_file, info_file_path, FS_O_WRITE | FS_O_CREATE);
    if (res) {
        LOG_ERR("error opening file %d", res);
        k_mutex_unlock(&sd_mutex);
        return -1;
    }

    res = fs_write(&write_file, buf, sizeof(buf));
    fs_close(&write_file);
    k_mutex_unlock(&sd_mutex);

    if (res < 0) {
        LOG_ERR("error writing file %d", res);
        return -1;
    }
    return 0;
}

int get_offset()
{
    uint8_t buf[4] = {0};
    struct fs_file_t read_file;
    fs_file_t_init(&read_file);

    k_mutex_lock(&sd_mutex, K_FOREVER);

    int rc = fs_open(&read_file, info_file_path, FS_O_READ | FS_O_RDWR);
    if (rc < 0) {
        LOG_ERR("error opening file %d", rc);
        k_mutex_unlock(&sd_mutex);
        return -1;
    }

    rc = fs_seek(&read_file, 0, FS_SEEK_SET);
    if (rc >= 0) {
        rc = fs_read(&read_file, buf, sizeof(buf));
    }

    fs_close(&read_file);
    k_mutex_unlock(&sd_mutex);

    if (rc < 0) {
        LOG_ERR("error reading offset %d", rc);
        return -1;
    }

    uint32_t offset = buf[0] | (buf[1] << 8) | (buf[2] << 16) | ((uint32_t) buf[3] << 24);
    LOG_INF("get offset is %u", offset);

    /* ponytail: the offset is returned through an int, so anything at or above
     * 2 GiB cannot be represented. The recording file never approaches that, and
     * widening it would change get_offset()'s exported signature. */
    return (int) offset;
}

void sd_off()
{
    //    gpio_pin_set_dt(&sd_en_gpio_pin, 0);
    sd_enabled = false;
}

void sd_on()
{
    //    gpio_pin_set_dt(&sd_en_gpio_pin, 1);
    sd_enabled = sd_mounted;
}

bool is_sd_on()
{
    return sd_enabled;
}

uint8_t sd_file_count(void)
{
    k_mutex_lock(&sd_mutex, K_FOREVER);
    uint8_t count = file_count;
    k_mutex_unlock(&sd_mutex);
    return count;
}

void sd_read_file_sizes(uint32_t out[2])
{
    k_mutex_lock(&sd_mutex, K_FOREVER);
    out[0] = file_num_array[0];
    out[1] = file_num_array[1];
    k_mutex_unlock(&sd_mutex);
}

void sd_set_file_sizes(uint32_t recorded_size, uint32_t saved_offset)
{
    k_mutex_lock(&sd_mutex, K_FOREVER);
    file_num_array[0] = recorded_size;
    file_num_array[1] = saved_offset;
    k_mutex_unlock(&sd_mutex);
}
