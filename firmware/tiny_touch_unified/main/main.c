#include "esp_err.h"
#include "esp_ota_ops.h"
#include "nvs_flash.h"

#include "config_console.h"
#include "device_config.h"
#include "fingerprint.h"
#include "piv.h"
#include "touch_pin_hid.h"
#include "usb_ccid.h"

void app_main(void) {
  ESP_ERROR_CHECK(nvs_flash_init());
  device_config_init();
  fingerprint_init();
  piv_init();
  usb_ccid_start(piv_handle_apdu);
  config_console_start();
  touch_pin_hid_start();

  const esp_partition_t *running = esp_ota_get_running_partition();
  esp_ota_img_states_t state;
  if (running && esp_ota_get_state_partition(running, &state) == ESP_OK &&
      state == ESP_OTA_IMG_PENDING_VERIFY) {
    ESP_ERROR_CHECK(esp_ota_mark_app_valid_cancel_rollback());
  }
}
