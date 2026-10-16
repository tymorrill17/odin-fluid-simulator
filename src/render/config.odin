package render

import "base:intrinsics"
import "core:encoding/ini"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"

CONFIG_FILE :: "config.ini"
CONFIG_PATH :: CACHE_DIR + "/" + CONFIG_FILE

// One section of the config file
ConfigSection :: struct {
    name: string, // name to appear in the .ini file header
    data: rawptr, // the config struct
    type: typeid, // the config struct type
}

@(private="file")
g_last_saved_settings: string

config_section :: proc(name: string, data: ^$T) -> ConfigSection where intrinsics.type_is_struct(T) {
    return { name, data, T }
}

config_load :: proc(sections: []ConfigSection) {
    // Parse the ini file into a map
    settings, _, ok := ini.load_map_from_path(CONFIG_PATH, context.temp_allocator)
    if !ok {
        log.infof("No config file at %s. Using defaults...", CONFIG_PATH)
        return
    }

    // For each config type, check to see if the ini contains a section for it and update the struct values
    for section in sections {
        pairs, has_section := settings[section.name]
        if !has_section do continue

        for key, value in pairs {
            field := reflect.struct_field_by_name(section.type, key)
            if field.type == nil {
                log.warnf("Config: unknown key [%s] %s, ignoring...", section.name, key)
                continue
            }
            if !config_parse_value(rawptr(uintptr(section.data) + field.offset), field.type.id, value) {
                log.warnf("Config: bad value \"%s\" for [%s] %s, keeping default", value, section.name, key)
            }
        }
    }
}

// Writes every field of every section to the settings file. Skips the write if nothing changed since the last save.
config_save :: proc(sections: []ConfigSection) {
    // First, write the whole ini file to a string
    b := strings.builder_make(context.temp_allocator)
    w := strings.to_writer(&b)
    for section, i in sections {
        if i > 0 do strings.write_byte(&b, '\n')
        ini.write_section(w, section.name)
        for field in reflect.struct_fields_zipped(section.type) {
            ini.write_pair(w, field.name, any{ rawptr(uintptr(section.data) + field.offset), field.type.id })
        }
    }

    // Compare this string vs the previous version
    text := strings.to_string(b)
    if text == g_last_saved_settings do return // no change, just return

    // Write to a temp file first so a crash mid-write can't leave a corrupt settings file
    tmp_path := CONFIG_PATH + ".tmp"
    if err := os.write_entire_file(tmp_path, text); err != nil {
        log.errorf("Failed to write %s: %v", tmp_path, err)
        return
    }
    if err := os.rename(tmp_path, CONFIG_PATH); err != nil {
        log.errorf("Failed to move %s to %s: %v", tmp_path, CONFIG_PATH, err)
        return
    }

    delete(g_last_saved_settings)
    g_last_saved_settings = strings.clone(text)
}

@(private="file")
config_parse_value :: proc(ptr: rawptr, type: typeid, text: string) -> bool {
    text := strings.trim_space(text)
    switch type {
    case f32:
        (^f32)(ptr)^ = strconv.parse_f32(text) or_return
    case u32:
        value := strconv.parse_uint(text, 10) or_return
        if value > uint(max(u32)) do return false
        (^u32)(ptr)^ = u32(value)
    case float4:
        parts := strings.split(strings.trim(text, "[] "), ",", context.temp_allocator)
        if len(parts) != 4 do return false
        value: float4
        for part, i in parts {
            value[i] = strconv.parse_f32(strings.trim_space(part)) or_return
        }
        (^float4)(ptr)^ = value
    case:
        log.errorf("Settings: no parser for type %v, add one to config_parse_value", type)
        return false
    }
    return true
}
