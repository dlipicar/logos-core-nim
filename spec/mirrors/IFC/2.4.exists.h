typedef logos_result_t (*logos_storage_Exists_FN_t)(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    const char*             in_cid,
    bool*                   out_exists
);

logos_result_t logos_storage_module_CALL_storage_Exists(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    const char*            in_cid,       /* from request map */
    bool*                  out_exists    /* from response map */
);
