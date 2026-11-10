typedef struct logos_map_recursive_left logos_recursive_left_t;
typedef struct logos_map_recursive_node logos_recursive_node_t;
typedef struct logos_map_recursive_right logos_recursive_right_t;

struct logos_map_recursive_left {
    bool                          has_right;
    const logos_recursive_right_t* right;
};

struct logos_map_recursive_node {
    bool                         has_next;
    const logos_recursive_node_t* next;
    uint64_t                     value;
};

struct logos_map_recursive_right {
    bool                         has_left;
    const logos_recursive_left_t* left;
};

typedef struct logos_map_recursive_branch {
    logos_recursive_node_t node;
} logos_recursive_branch_t;
