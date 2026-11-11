typedef uint32_t logos_storage_Value_KIND_t;
#define LOGOS_ARM_storage_Value_CASE_Bool 0u
#define LOGOS_ARM_storage_Value_CASE_Tstr 1u
#define LOGOS_ARM_storage_Value_CASE_Uint64 2u

typedef struct logos_storage_Value_CHOICE {
    logos_storage_Value_KIND_t kind;
    union {
        bool        arm_Bool;
        const char* arm_Tstr;
        uint64_t    arm_Uint64;
    } value;
} logos_storage_Value_t;
