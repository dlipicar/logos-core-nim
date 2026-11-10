typedef struct logos_event_storage_upload_progress_event {
    uint64_t    bytes_sent;
    uint64_t    bytes_total;
    const char* session;
} logos_storage_upload_progress_event_t;
