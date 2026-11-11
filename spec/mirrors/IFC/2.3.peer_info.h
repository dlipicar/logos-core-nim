typedef struct logos_storage_Peer_info_MAP {
    const char* id;
    bool        has_name;
    const char* name;       /* valid only if has_name == true */
} logos_storage_Peer_info_t;
