typedef enum {
    LOGOS_STORAGE_VALUE_ARM_0 = 0,
    LOGOS_STORAGE_VALUE_ARM_1 = 1,
    LOGOS_STORAGE_VALUE_ARM_2 = 2,
} logos_storage_value_kind_t;

typedef struct logos_choice_storage_value {
    logos_storage_value_kind_t kind;
    union {
        bool        arm_0;
        const char* arm_1;
        uint64_t    arm_2;
    } value;
} logos_storage_value_t;
