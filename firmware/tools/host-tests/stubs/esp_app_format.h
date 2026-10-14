#pragma once
// esp_app_desc_t, reduced to the two fields ota_update.cpp reads, at their real widths (32 bytes
// each on IDF 4.4 and 5). The magic word, timestamps, idf_ver and ELF sha256 are not modelled.
struct esp_app_desc_t {
    char version[32];
    char project_name[32];
};
