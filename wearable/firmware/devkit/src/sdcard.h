/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#ifndef SDCARD_H
#define SDCARD_H

#include <stdbool.h>
#include <stdint.h>

/* On-card block size. Audio is stored as fixed 440-byte blocks holding a run of
 * length-prefixed Opus frames ([len][payload][len][payload]...). transport.c
 * packs blocks, storage.c ships them back over GATT one block per notify, so
 * both sides must agree on this number. */
#define SD_BLOCK_SIZE 440

/**
 * @brief Mount the SD Card. Initializes the audio files
 *
 * Mounts the SD Card and initializes the audio files. If the SD card does not contain those files, the
 * function will create them.
 *
 * @return 0 if successful, negative errno code if error
 */
int mount_sd_card(void);

/**
 * @brief Create a file
 *
 * Creates a file at the given path
 *
 * @return 0 if successful, negative errno code if error
 */
int create_file(const char *file_path);
// private
char *generate_new_audio_header(uint8_t num);

/**
 * @brief Initialize an audio file of number 1
 *
 * Initializes an audio file. It will be called a nn.txt, where nn is the number of the file.
 *  example: initialize_audio_file(1) will create a file called a01.txt
 * @return 0 if successful, negative errno code if error
 */
int initialize_audio_file(uint8_t num);

/**
 * @brief Write to the current audio file specified by the write pointer
 *
 *
 *
 * @return number of bytes written
 */
int write_to_file(uint8_t *data, uint32_t length);

/**
 * @brief Read from the current audio file specified by the read pointer
 *
 *
 *
 * @return number of bytes read
 */
int read_audio_data(uint8_t *buf, int amount, int offset);
/**
 * @brief Get the size of the specified audio file number
 *
 *
 *
 * @return size of the file in bytes
 */
uint32_t get_file_size(uint8_t num);

/**
 * @brief Move the read pointer to the specified audio file position
 *
 *
 *
 * @return 0 if successful, negative errno code if error
 */
int move_read_pointer(uint8_t num);

/**
 * @brief Move the write pointer to the specified audio file position
 *
 *
 *
 * @return 0 if successful, negative errno code if error
 */
int move_write_pointer(uint8_t num);

/**
 * @brief Clear the specified audio file
 *
 *
 *
 * @return 0 if successful, negative errno code if error
 */
int clear_audio_file(uint8_t num);

/**
 * @brief Clear the audio directory.
 *
 * This deletes all audio files and leaves the audio directory with only one file left, a01.txt.
 * This automatically moves the read and write pointers to a01.txt.
 * @return 0 if successful, negative errno code if error
 */
int clear_audio_directory();

int save_offset(uint32_t offset);
int get_offset();

void sd_on();
void sd_off();

bool is_sd_on();

/*
 * Cached audio-file metadata.
 *
 * The file count and the two cached sizes used to live here as bare globals
 * (file_count, file_num_array[2]) and were read and written by the pusher
 * thread, the storage thread and the BLE RX thread with no lock at all. They
 * are now private to sdcard.c behind the same mutex that serialises every FAT
 * access, and reached only through these accessors.
 *
 * sd_read_file_sizes() fills out[0] with the on-disk size of the file being
 * recorded and out[1] with the last offset saved to info.txt -- the same two
 * words the storage read characteristic hands to the phone, so the layout on
 * the wire is unchanged.
 */
uint8_t sd_file_count(void);
void sd_read_file_sizes(uint32_t out[2]);
void sd_set_file_sizes(uint32_t recorded_size, uint32_t saved_offset);

#endif
