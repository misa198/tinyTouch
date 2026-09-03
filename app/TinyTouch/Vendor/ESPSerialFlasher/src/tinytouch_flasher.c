#include "tinytouch_flasher.h"

#include "esp_loader.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <IOKit/serial/ioss.h>

typedef struct {
    esp_loader_port_t port;
    const char *path;
    int fd;
    int64_t deadline;
    bool manual_boot;
} tt_port_t;

static int64_t now_ms(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (int64_t)time.tv_sec * 1000 + time.tv_nsec / 1000000;
}

static void message(char *out, size_t size, const char *format, ...) {
    if (!out || !size) return;
    va_list args;
    va_start(args, format);
    vsnprintf(out, size, format, args);
    va_end(args);
}

static int open_serial(const char *path, uint32_t baud) {
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFL, 0);
    struct termios settings;
    if (tcgetattr(fd, &settings)) {
        close(fd);
        return -1;
    }
    cfmakeraw(&settings);
    if (tcsetattr(fd, TCSANOW, &settings)) { close(fd); return -1; }
    speed_t speed = baud;
    if (ioctl(fd, IOSSIOSPEED, &speed)) {
        close(fd);
        return -1;
    }
    tcflush(fd, TCIOFLUSH);
    return fd;
}

static esp_loader_error_t port_init(esp_loader_port_t *base) {
    tt_port_t *port = container_of(base, tt_port_t, port);
    port->fd = open_serial(port->path, 115200);
    return port->fd < 0 ? ESP_LOADER_ERROR_FAIL : ESP_LOADER_SUCCESS;
}

static void port_deinit(esp_loader_port_t *base) {
    tt_port_t *port = container_of(base, tt_port_t, port);
    if (port->fd >= 0) close(port->fd);
    port->fd = -1;
}

static void signals(tt_port_t *port, bool dtr, bool rts) {
    int bits = 0;
    if (dtr) bits |= TIOCM_DTR;
    if (rts) bits |= TIOCM_RTS;
    ioctl(port->fd, TIOCMSET, &bits);
}

static void delay_ms(esp_loader_port_t *base, uint32_t ms) { (void)base; usleep(ms * 1000); }

static void enter_bootloader(esp_loader_port_t *base) {
    tt_port_t *port = container_of(base, tt_port_t, port);
    if (port->manual_boot) return;
    signals(port, false, false);
    signals(port, true, true);
    signals(port, false, true);
    usleep(100000);
    signals(port, true, false);
    usleep(50000);
    signals(port, false, false);
    tcflush(port->fd, TCIFLUSH);
}

static void reset_target(esp_loader_port_t *base) {
    tt_port_t *port = container_of(base, tt_port_t, port);
    signals(port, false, true);
    usleep(100000);
    signals(port, false, false);
}

static void start_timer(esp_loader_port_t *base, uint32_t ms) {
    container_of(base, tt_port_t, port)->deadline = now_ms() + ms;
}

static uint32_t remaining_time(esp_loader_port_t *base) {
    int64_t value = container_of(base, tt_port_t, port)->deadline - now_ms();
    return value > 0 ? (uint32_t)value : 0;
}

static esp_loader_error_t serial_write(esp_loader_port_t *base, const uint8_t *data,
                                       uint16_t size, uint32_t timeout) {
    tt_port_t *port = container_of(base, tt_port_t, port);
    size_t offset = 0;
    int64_t deadline = now_ms() + timeout;
    while (offset < size && now_ms() < deadline) {
        ssize_t count = write(port->fd, data + offset, size - offset);
        if (count > 0) offset += (size_t)count;
        else if (errno != EINTR && errno != EAGAIN) return ESP_LOADER_ERROR_FAIL;
    }
    return offset == size && tcdrain(port->fd) == 0 ? ESP_LOADER_SUCCESS : ESP_LOADER_ERROR_TIMEOUT;
}

static esp_loader_error_t serial_read(esp_loader_port_t *base, uint8_t *data,
                                      uint16_t size, uint32_t timeout) {
    tt_port_t *port = container_of(base, tt_port_t, port);
    size_t offset = 0;
    int64_t deadline = now_ms() + timeout;
    while (offset < size && now_ms() < deadline) {
        ssize_t count = read(port->fd, data + offset, size - offset);
        if (count > 0) offset += (size_t)count;
        else if (count < 0 && errno != EINTR && errno != EAGAIN) return ESP_LOADER_ERROR_FAIL;
        else usleep(1000);
    }
    return offset == size ? ESP_LOADER_SUCCESS : ESP_LOADER_ERROR_TIMEOUT;
}

static esp_loader_error_t change_rate(esp_loader_port_t *base, uint32_t baud) {
    tt_port_t *port = container_of(base, tt_port_t, port);
    speed_t speed = baud;
    return ioctl(port->fd, IOSSIOSPEED, &speed) == 0 ? ESP_LOADER_SUCCESS : ESP_LOADER_ERROR_FAIL;
}

static const esp_loader_port_ops_t operations = {
    .init = port_init, .deinit = port_deinit, .enter_bootloader = enter_bootloader,
    .reset_target = reset_target, .start_timer = start_timer, .remaining_time = remaining_time,
    .delay_ms = delay_ms, .change_transmission_rate = change_rate,
    .write = serial_write, .read = serial_read,
};

int tt_flash_factory(const char *path, const char *image_path, bool manual_boot,
                     tt_flash_progress_t progress, void *context,
                     char *error, size_t error_size) {
    if (!path || !image_path) return TT_FLASH_IO;
    FILE *file = fopen(image_path, "rb");
    if (!file) { message(error, error_size, "Cannot open firmware image."); return TT_FLASH_IO; }
    fseek(file, 0, SEEK_END);
    long file_size = ftell(file);
    fseek(file, 0, SEEK_SET);
    if (file_size <= 0 || file_size > 4 * 1024 * 1024) {
        fclose(file); message(error, error_size, "Firmware image size is invalid."); return TT_FLASH_IO;
    }
    size_t size = ((size_t)file_size + 3) & ~(size_t)3;
    uint8_t *image = malloc(size);
    if (!image) { fclose(file); message(error, error_size, "Not enough memory for firmware image."); return TT_FLASH_IO; }
    memset(image, 0xff, size);
    bool read_ok = fread(image, 1, (size_t)file_size, file) == (size_t)file_size;
    fclose(file);
    if (!read_ok) { free(image); message(error, error_size, "Cannot read firmware image."); return TT_FLASH_IO; }

    tt_port_t darwin = {.port.ops = &operations, .path = path, .fd = -1, .manual_boot = manual_boot};
    esp_loader_t loader;
    esp_loader_error_t result = esp_loader_init_serial(&loader, &darwin.port);
    if (result != ESP_LOADER_SUCCESS) {
        free(image); message(error, error_size, "Cannot open serial port."); return TT_FLASH_IO;
    }
    esp_loader_connect_args_t connect = ESP_LOADER_CONNECT_DEFAULT();
    result = esp_loader_connect_with_stub(&loader, &connect);
    if (result != ESP_LOADER_SUCCESS) {
        esp_loader_deinit(&loader); free(image);
        message(error, error_size, manual_boot ? "Could not connect to the ROM bootloader." : "Automatic bootloader entry failed.");
        return TT_FLASH_CONNECT;
    }
    if (esp_loader_get_target(&loader) != ESP32S3_CHIP) {
        esp_loader_deinit(&loader); free(image); message(error, error_size, "Connected chip is not ESP32-S3.");
        return TT_FLASH_WRONG_CHIP;
    }
    esp_loader_flash_cfg_t flash = {.offset = 0, .image_size = (uint32_t)size, .block_size = 1024};
    result = esp_loader_flash_start(&loader, &flash);
    if (result == ESP_LOADER_SUCCESS) {
        for (size_t offset = 0; offset < size; offset += 1024) {
            uint32_t count = (uint32_t)((size - offset) < 1024 ? size - offset : 1024);
            result = esp_loader_flash_write(&loader, &flash, image + offset, count);
            if (result != ESP_LOADER_SUCCESS) break;
            if (progress) progress((double)(offset + count) / (double)size, context);
        }
    }
    if (result == ESP_LOADER_SUCCESS) result = esp_loader_flash_finish(&loader, &flash);
    if (result == ESP_LOADER_SUCCESS) esp_loader_reset_target(&loader);
    esp_loader_deinit(&loader);
    free(image);
    if (result == ESP_LOADER_ERROR_INVALID_MD5) {
        message(error, error_size, "Flash verification failed."); return TT_FLASH_VERIFY;
    }
    if (result != ESP_LOADER_SUCCESS) {
        message(error, error_size, "Serial write failed or the device disconnected."); return TT_FLASH_WRITE;
    }
    return TT_FLASH_OK;
}
