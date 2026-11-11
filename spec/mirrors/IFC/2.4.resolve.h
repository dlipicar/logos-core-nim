typedef logos_result_t (*logos_storage_Resolve_FN_t)(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    const logos_storage_Resolve_request_t* in_request,
    bool* out_matched
);
