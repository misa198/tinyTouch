#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*tt_flash_progress_t)(double progress, void *context);

enum {
    TT_FLASH_OK = 0,
    TT_FLASH_IO = 1,
    TT_FLASH_CONNECT = 2,
    TT_FLASH_WRONG_CHIP = 3,
    TT_FLASH_WRITE = 4,
    TT_FLASH_VERIFY = 5,
};

int tt_flash_factory(const char *port, const char *image_path, bool manual_boot,
                     tt_flash_progress_t progress, void *context,
                     char *error, size_t error_size);

#ifdef __cplusplus
}
#endif
