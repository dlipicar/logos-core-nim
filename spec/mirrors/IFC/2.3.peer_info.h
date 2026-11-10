typedef struct logos_map_storage_peer_info {
    const char* id;
    bool        has_name;
    const char* name;       /* valid only if has_name == true */
} logos_storage_peer_info_t;
