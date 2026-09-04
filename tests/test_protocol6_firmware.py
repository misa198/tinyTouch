import unittest
from pathlib import Path


PROJECT = Path(__file__).parents[1] / "firmware" / "tiny_touch_unified"
MAIN = PROJECT / "main"


class ProtocolSixFirmwareTests(unittest.TestCase):
    def source(self, name: str) -> str:
        return (MAIN / name).read_text()

    def test_no_firmware_software_restart_path(self) -> None:
        source = "\n".join(path.read_text() for path in MAIN.glob("*.c"))
        self.assertNotIn("esp_restart", source)
        self.assertNotIn("RTC_CNTL_FORCE_DOWNLOAD_BOOT", source)

    def test_watchdog_does_not_monitor_tinyusb_core_idle_task(self) -> None:
        defaults = (PROJECT / "sdkconfig.defaults").read_text()
        self.assertIn("CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU0=y", defaults)
        self.assertIn("CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU1=n", defaults)

    def test_protocol_six_has_one_stable_usb_descriptor(self) -> None:
        cmake = self.source("CMakeLists.txt")
        usb = self.source("usb_ccid.c")
        descriptors = self.source("usb_descriptors.c")
        self.assertIn("TINYTOUCH_PROTOCOL_VERSION=6", cmake)
        self.assertIn("tiny_touch_configuration_descriptor", usb)
        self.assertNotIn("tiny_touch_hid_configuration_descriptor", descriptors)
        self.assertNotIn("tiny_touch_piv_configuration_descriptor", descriptors)
        self.assertIn('"misa198"', descriptors)
        self.assertIn('"misa198 tinyTouch"', descriptors)
        self.assertIn('"MISA198-TT-%02X', descriptors)
        self.assertIn("0x42, 0x00, 0x02, 0x00", descriptors)
        self.assertIn("product_id=misa198.tinytouch.v1", self.source("config_console.c"))

    def test_persistence_swaps_one_live_config_blob(self) -> None:
        source = self.source("device_config.c")
        self.assertIn('CONFIG_NAMESPACE "tt6"', source)
        self.assertIn("replace_locked", source)
        self.assertIn("device_config_factory_reset", source)
        self.assertNotIn('"hid_key"', source)
        self.assertNotIn('"hid_hosts"', source)

    def test_host_listing_is_read_only_and_uses_lowercase_ids(self) -> None:
        console = self.source("config_console.c")
        self.assertIn('strcmp(command, "HOST LIST")', console)
        self.assertIn('"0123456789abcdef"', console)
        self.assertIn('"OK HOST LIST ids=%s capacity=%u"', console)

    def test_cdc_tx_buffer_fits_protocol_status_frames(self) -> None:
        for name in ("sdkconfig.defaults", "sdkconfig"):
            config = (PROJECT / name).read_text()
            size = int(config.split("CONFIG_TINYUSB_CDC_TX_BUFSIZE=", 1)[1].splitlines()[0])
            self.assertGreaterEqual(size, 320)

    def test_ota_stages_without_changing_the_current_runtime(self) -> None:
        console = self.source("config_console.c")
        update = self.source("firmware_update.c")
        main = self.source("main.c")
        self.assertIn("OK OTA STAGED power_cycle=required", console)
        self.assertIn("esp_ota_set_boot_partition", update)
        self.assertIn("firmware_update_staged", update)
        self.assertIn("ESP_OTA_IMG_PENDING_VERIFY", main)
        self.assertIn("esp_ota_mark_app_valid_cancel_rollback", main)
        self.assertNotIn("fingerprint_prepare_for_restart", console)

    def test_piv_create_is_live_and_status_reports_readiness(self) -> None:
        console = self.source("config_console.c")
        piv = self.source("piv.c")
        self.assertIn('strcmp(command, "PIV CREATE")', console)
        self.assertIn('piv_uses_provisioned_keys() ? "ready" : "unconfigured"', console)
        self.assertIn("piv_create_identity", piv)
        self.assertIn("piv_reload_keys()", piv)
        self.assertNotIn("char cert_9a[sizeof", piv)

    def test_piv_certificates_are_usable_as_macos_identities(self) -> None:
        piv = self.source("piv.c")
        self.assertIn("MBEDTLS_X509_KU_DIGITAL_SIGNATURE", piv)
        self.assertIn("MBEDTLS_OID_CLIENT_AUTH", piv)
        self.assertIn("mbedtls_x509write_crt_set_ext_key_usage", piv)

    def test_piv_accepts_macos_signing_template(self) -> None:
        piv = self.source("piv.c")
        self.assertIn("tag == 0x81 && len > 0 && !*challenge", piv)
        self.assertIn("tag == 0x80 && len > 0 && !witness", piv)
        self.assertIn("tag == 0x82 && len > 0 && !response", piv)
        self.assertIn("size_t chained_le = apdu_le(apdu, apdu_len, 0)", piv)
        self.assertIn("respond_maybe_chunked(auth_result, off, apdu, apdu_len", piv)

    def test_piv_dummy_pin_matches_documented_value(self) -> None:
        piv = self.source("piv.c")
        hid = self.source("touch_pin_hid.c")
        self.assertIn("'0', '0', '0', '0', '0', '0', 0xff, 0xff", piv)
        self.assertIn("HID_KEY_KEYPAD_0", hid)
        self.assertNotIn("HID_KEY_KEYPAD_1", hid)

    def test_fingerprint_auth_requires_presence(self) -> None:
        source = self.source("touch_pin_hid.c")
        self.assertIn("if (!present || !tud_hid_ready())", source)
        self.assertNotIn("!fingerprint_is_ready()", source)
        self.assertNotIn("fingerprint_service_health", source)
        self.assertNotIn("usb_runtime", source)

    def test_factory_reset_erases_fingerprints_and_nvs(self) -> None:
        source = self.source("config_console.c")
        self.assertIn("fingerprint_delete_all() && nvs_flash_erase()", source)
        self.assertIn('strcmp(command, "RESET FACTORY")', source)

    def test_enrollment_emits_fingerprint_prompts(self) -> None:
        source = self.source("config_console.c")
        self.assertIn('"PROMPT %s"', source)
        self.assertIn("fingerprint_enroll((uint16_t)slot, fingerprint_prompt)", source)

    def test_status_reports_exact_fingerprint_slots_and_live_settings(self) -> None:
        console = self.source("config_console.c")
        config = self.source("device_config.c")
        fingerprint = self.source("fingerprint.c")
        self.assertIn("fingerprint_slot_mask()", console)
        self.assertIn("fingerprint_slots=%s", console)
        self.assertIn("fingerprints=%s", console)
        self.assertNotIn("} else {\n    count = fingerprint_count();", console)
        self.assertIn("type_delay=%u submit_enter=%u cooldown=%u led_idle=%u", console)
        self.assertIn('strcmp(arguments, "LED_IDLE")', console)
        self.assertIn("bool value = !config.idle_led_off", config)
        self.assertIn("FP_LED_FUNC_OFF", fingerprint)
        self.assertIn("fp_command(0x1f", fingerprint)


if __name__ == "__main__":
    unittest.main()
