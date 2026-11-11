typedef struct logos_recursive_Left_MAP logos_recursive_Left_t;
typedef struct logos_recursive_Node_MAP logos_recursive_Node_t;
typedef struct logos_recursive_Right_MAP logos_recursive_Right_t;

struct logos_recursive_Left_MAP {
    bool                          has_right;
    const logos_recursive_Right_t* right;
};

struct logos_recursive_Node_MAP {
    bool                         has_next;
    const logos_recursive_Node_t* next;
    uint64_t                     value;
};

struct logos_recursive_Right_MAP {
    bool                         has_left;
    const logos_recursive_Left_t* left;
};

typedef struct logos_recursive_Branch_MAP {
    logos_recursive_Node_t node;
} logos_recursive_Branch_t;
