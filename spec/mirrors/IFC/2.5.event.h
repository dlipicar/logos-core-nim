typedef struct logos_storage_Upload_progress_event_EVENT {
    uint64_t    bytes_sent;
    uint64_t    bytes_total;
    const char* session;
} logos_storage_Upload_progress_event_t;
