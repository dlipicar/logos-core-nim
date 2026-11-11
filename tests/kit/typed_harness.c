/* Typed provider calls as a C caller makes them (INTERFACE §2.4, §2.7.1), for
 * tests/test_kit.nim and tests/test_kit_dylib.nim.
 *
 * Each th_* function builds its inputs in C, initializes the response owner
 * and every output object to zero (the caller's §2.4 duty), calls the provider
 * function it is given, and fills a th_report_t:
 *
 * - the result and the owner as returned; the harness never clears the owner,
 *   so the Nim side can check it and release it, on any thread;
 * - whether the owner and every output object are still all zero;
 * - on success, the outputs as text, and whether every pointer a complete
 *   output needs (text, byte string and list storage, even when empty) is
 *   non-null.
 *
 * The reflect method's response repeats its request, so its report also says
 * whether the outputs read back exactly as the inputs. */

#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

#include "typed_harness.h"

void th_sizes(size_t* fns, size_t* report, size_t* text, size_t* helpers)
{
    *helpers = sizeof(th_helpers_t);
    *fns = sizeof(th_fns_t);
    *report = sizeof(th_report_t);
    *text = offsetof(th_report_t, text);
}

/* INTERFACE §4.5.1's default payload depth limit. The params map is level 1,
 * in_u's root tree level 2, and each tree's `kids` array one level below its
 * tree: a chain of TH_CHAIN - 1 left trees nests to the limit exactly, and
 * TH_CHAIN trees one level past it. */
#define TH_DEPTH_LIMIT 1024
#define TH_CHAIN (TH_DEPTH_LIMIT - 1)

/* Text ------------------------------------------------------------------------ */

typedef struct {
    char* p;
    size_t cap;
    size_t len;
    int nulls; /* null pointers met where a complete value has storage */
} sb_t;

static sb_t sb_on(char* p, size_t cap)
{
    sb_t b = {p, cap, 0, 0};
    p[0] = 0;
    return b;
}

static void sbf(sb_t* b, const char* fmt, ...)
{
    if (b->len + 1 >= b->cap)
        return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(b->p + b->len, b->cap - b->len, fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    b->len += (size_t)n;
    if (b->len >= b->cap)
        b->len = b->cap - 1;
}

static void dump_text(sb_t* b, const char* s)
{
    if (s == NULL) {
        b->nulls++;
        sbf(b, "null");
    } else {
        sbf(b, "\"%s\"", s);
    }
}

static void dump_hex(sb_t* b, const uint8_t* p, size_t n)
{
    sbf(b, "h'");
    for (size_t i = 0; i < n; i++)
        sbf(b, "%02x", p[i]);
    sbf(b, "'");
}

static void dump_bytes(sb_t* b, const uint8_t* p, size_t n)
{
    if (p == NULL) {
        b->nulls++;
        if (n > 0) {
            sbf(b, "NULL[%zu]", n);
            return;
        }
    }
    dump_hex(b, p, n);
}

static void note_list(sb_t* b, const void* p)
{
    if (p == NULL)
        b->nulls++;
}

static int all_zero(const void* p, size_t n)
{
    const unsigned char* c = (const unsigned char*)p;
    for (size_t i = 0; i < n; i++)
        if (c[i] != 0)
            return 0;
    return 1;
}

static void finish(th_report_t* rep, logos_result_t r, logos_response_owner_t owner,
                   const void* outs, size_t outs_size)
{
    rep->result = r;
    rep->owner = owner;
    rep->untouched =
        all_zero(&owner, sizeof owner) && (outs == NULL || all_zero(outs, outs_size));
    rep->complete = 0;
    rep->same = 0;
}

/* Shared shapes ---------------------------------------------------------------- */

static void dump_value(sb_t* b, const logos_shapes_Value_t* v)
{
    switch (v->kind) {
    case LOGOS_ARM_shapes_Value_CASE_Bool:
        sbf(b, "%s", v->value.arm_Bool ? "true" : "false");
        break;
    case LOGOS_ARM_shapes_Value_CASE_Tstr:
        dump_text(b, v->value.arm_Tstr);
        break;
    case LOGOS_ARM_shapes_Value_CASE_Uint64:
        sbf(b, "%" PRIu64, v->value.arm_Uint64);
        break;
    default:
        sbf(b, "?%u", (unsigned)v->kind);
    }
}

static void dump_entry(sb_t* b, const logos_shapes_Entry_t* e)
{
    switch (e->kind) {
    case LOGOS_ARM_shapes_Entry_CASE_Dir:
        sbf(b, "dir{kind=");
        dump_text(b, e->value.arm_Dir.kind);
        sbf(b, " path=");
        dump_text(b, e->value.arm_Dir.path);
        sbf(b, " entries=[");
        for (size_t k = 0; k < e->value.arm_Dir.entries_count; k++) {
            if (k)
                sbf(b, ",");
            dump_text(b, e->value.arm_Dir.entries[k]);
        }
        note_list(b, e->value.arm_Dir.entries);
        sbf(b, "]}");
        break;
    case LOGOS_ARM_shapes_Entry_CASE_File:
        sbf(b, "file{kind=");
        dump_text(b, e->value.arm_File.kind);
        sbf(b, " path=");
        dump_text(b, e->value.arm_File.path);
        sbf(b, "}");
        break;
    default:
        sbf(b, "?%u", (unsigned)e->kind);
    }
}

static void dump_tree(sb_t* b, const logos_shapes_Tree_t* t, int depth)
{
    if (depth > TH_CHAIN + 8) {
        sbf(b, "DEEP");
        return;
    }
    sbf(b, "{kids=[");
    for (size_t k = 0; k < t->kids_count; k++) {
        if (k)
            sbf(b, ",");
        dump_tree(b, &t->kids[k], depth + 1);
    }
    note_list(b, t->kids);
    sbf(b, "]");
    if (t->has_left) {
        sbf(b, " left=");
        if (t->left == NULL) {
            b->nulls++;
            sbf(b, "NULL");
        } else {
            dump_tree(b, t->left, depth + 1);
        }
    }
    sbf(b, " tag=");
    dump_text(b, t->tag);
    if (t->has_twin) {
        sbf(b, " twin=");
        if (t->twin == NULL) {
            b->nulls++;
            sbf(b, "NULL");
        } else {
            sbf(b, "(");
            if (t->twin->item_0 == NULL) {
                b->nulls++;
                sbf(b, "NULL");
            } else {
                dump_tree(b, t->twin->item_0, depth + 1);
            }
            sbf(b, ",%" PRIu64 ")", t->twin->item_1);
        }
    }
    sbf(b, "}");
}

static void dump_names(sb_t* b, const logos_shapes_Names_t* r)
{
    sbf(b, "[");
    for (size_t k = 0; k < r->count; k++) {
        if (k)
            sbf(b, ",");
        dump_text(b, r->items[k]);
    }
    note_list(b, r->items);
    sbf(b, "]");
}

static void dump_commitment(sb_t* b, const logos_schema_commitment_t* c)
{
    sbf(b, "(");
    dump_text(b, c->commitment_model);
    sbf(b, ",");
    dump_text(b, c->hash_profile);
    sbf(b, ",");
    dump_text(b, c->hash_suite);
    sbf(b, ",");
    dump_hex(b, c->schema_root, 32);
    sbf(b, ")");
}

/* The request's and the response's inline declarations are distinct C types
 * with the same members: one dumper for each. */
#define G_DUMPER(SIDE)                                                                   \
    static void dump_g_##SIDE(sb_t* b, const logos_shapes_Reflect_##SIDE##_G_t* g)      \
    {                                                                                    \
        switch (g->kind) {                                                               \
        case LOGOS_ARM_shapes_Reflect_##SIDE##_G_CASE_Tuple1:                            \
            sbf(b, "[%" PRIu64 "]", g->value.arm_Tuple1.item_0);                         \
            break;                                                                       \
        case LOGOS_ARM_shapes_Reflect_##SIDE##_G_CASE_Tuple2:                            \
            sbf(b, "[%" PRIu64 ",%" PRIu64 "]", g->value.arm_Tuple2.item_0,              \
                g->value.arm_Tuple2.item_1);                                             \
            break;                                                                       \
        case LOGOS_ARM_shapes_Reflect_##SIDE##_G_CASE_shapes_Value:                      \
            sbf(b, "value:");                                                            \
            dump_value(b, &g->value.arm_shapes_Value);                                   \
            break;                                                                       \
        default:                                                                         \
            sbf(b, "?%u", (unsigned)g->kind);                                            \
        }                                                                                \
    }

G_DUMPER(request)
G_DUMPER(response)

/* Every reflect member in canonical field order, read from a struct `x` whose
 * members carry the field names (reflect_in_t or reflect_out_t). */
#define DUMP_REFLECT(SB, VAL, SIDE)                                                     \
    do {                                                                                \
        sbf(SB, "a=%" PRIu64 " b=%" PRId64 " c=", (VAL)->a, (VAL)->b);                  \
        dump_text(SB, (VAL)->c);                                                        \
        sbf(SB, " d=");                                                                 \
        dump_hex(SB, (VAL)->d, 32);                                                     \
        sbf(SB, " e=[");                                                                \
        for (size_t k_ = 0; k_ < (VAL)->e_count; k_++) {                                \
            if (k_)                                                                     \
                sbf(SB, ",");                                                           \
            dump_hex(SB, (VAL)->e[k_].data, 4);                                         \
        }                                                                               \
        note_list(SB, (VAL)->e);                                                        \
        sbf(SB, "] f=[");                                                               \
        for (size_t k_ = 0; k_ < (VAL)->f_count; k_++) {                                \
            if (k_)                                                                     \
                sbf(SB, ",");                                                           \
            sbf(SB, "(%" PRIu64 ",", (VAL)->f[k_].item_0);                              \
            dump_text(SB, (VAL)->f[k_].item_1);                                         \
            sbf(SB, ")");                                                               \
        }                                                                               \
        note_list(SB, (VAL)->f);                                                        \
        sbf(SB, "] g=");                                                                \
        dump_g_##SIDE(SB, &(VAL)->g);                                                   \
        if ((VAL)->has_h) {                                                             \
            sbf(SB, " h=(%" PRIu64 ",", (VAL)->h_0);                                    \
            dump_bytes(SB, (VAL)->h_1.data, (VAL)->h_1.len);                            \
            sbf(SB, ")");                                                               \
        } else {                                                                        \
            sbf(SB, " h=absent");                                                       \
        }                                                                               \
        sbf(SB, " i=");                                                                 \
        dump_commitment(SB, &(VAL)->i);                                                 \
        sbf(SB, " m=%d n=%u o=%u p=%d", (int)(VAL)->m, (unsigned)(VAL)->n,              \
            (unsigned)(VAL)->o, (int)(VAL)->p);                                         \
        if ((VAL)->has_q) {                                                             \
            sbf(SB, " q=");                                                             \
            dump_bytes(SB, (VAL)->q.data, (VAL)->q.len);                                \
        } else {                                                                        \
            sbf(SB, " q=absent");                                                       \
        }                                                                               \
        sbf(SB, " r=");                                                                 \
        dump_names(SB, &(VAL)->r);                                                      \
        sbf(SB, " s=");                                                                 \
        dump_bytes(SB, (VAL)->s, (VAL)->s_len);                                         \
        sbf(SB, " t=[");                                                                \
        for (size_t k_ = 0; k_ < (VAL)->t_count; k_++) {                                \
            if (k_)                                                                     \
                sbf(SB, ",");                                                           \
            dump_entry(SB, &(VAL)->t[k_]);                                              \
        }                                                                               \
        note_list(SB, (VAL)->t);                                                        \
        sbf(SB, "] u=");                                                                \
        dump_tree(SB, &(VAL)->u, 0);                                                    \
        sbf(SB, " v=(%s,", (VAL)->v.w ? "true" : "false");                              \
        if ((VAL)->v.has_x)                                                             \
            dump_text(SB, (VAL)->v.x);                                                  \
        else                                                                            \
            sbf(SB, "absent");                                                          \
        sbf(SB, ") y=");                                                                \
        dump_bytes(SB, (VAL)->y.data, (VAL)->y.len);                                    \
        sbf(SB, " z=");                                                                 \
        dump_hex(SB, (VAL)->z.data, 4);                                                 \
    } while (0)

/* meter_module ------------------------------------------------------------------ */

typedef struct {
    logos_tstr_size_1_64_t label;
    logos_meter_Reading_t reading;
} meter_out_t;

void th_meter_read(const th_fns_t* f, logos_module_context_t* m, uint32_t channel,
                   th_report_t* rep)
{
    meter_out_t o;
    memset(&o, 0, sizeof o);
    logos_response_owner_t owner = {0};
    logos_result_t r = f->meter_read(m, &owner, channel, &o.label, &o.reading);
    finish(rep, r, owner, &o, sizeof o);
    sb_t b = sb_on(rep->text, sizeof rep->text);
    if (r.code != LOGOS_OK)
        return;
    sbf(&b, "label=");
    dump_text(&b, o.label);
    sbf(&b, " reading=(");
    if (o.reading.has_label)
        dump_text(&b, o.reading.label);
    else
        sbf(&b, "absent");
    sbf(&b, ",%" PRIu64 ")", o.reading.value);
    rep->complete = b.nulls == 0;
}

/* sensor_module ----------------------------------------------------------------- */

void th_sensor_configure(const th_fns_t* f, logos_module_context_t* m,
                         const char* kind, uint64_t limit, th_report_t* rep)
{
    logos_sensor_NS_control_Settings_t s;
    memset(&s, 0, sizeof s);
    s.kind = kind;
    s.limit = limit;
    logos_response_owner_t owner = {0};
    logos_result_t r = f->sensor_configure(m, &owner, &s);
    finish(rep, r, owner, NULL, 0);
    sb_on(rep->text, sizeof rep->text);
    rep->complete = 1;
}

void th_sensor_snapshot(const th_fns_t* f, logos_module_context_t* m, th_report_t* rep)
{
    uint64_t count = 0;
    logos_response_owner_t owner = {0};
    logos_result_t r = f->sensor_snapshot(m, &owner, &count);
    finish(rep, r, owner, &count, sizeof count);
    sb_t b = sb_on(rep->text, sizeof rep->text);
    if (r.code != LOGOS_OK)
        return;
    sbf(&b, "count=%" PRIu64, count);
    rep->complete = 1;
}

/* shapes_module: reflect -------------------------------------------------------- */

typedef struct {
    uint64_t a;
    int64_t b;
    const char* c;
    uint8_t d[32];
    const logos_shapes_Reflect_request_E_LI_t* e;
    size_t e_count;
    const logos_shapes_Reflect_request_F_LI_t* f;
    size_t f_count;
    logos_shapes_Reflect_request_G_t g;
    bool has_h;
    uint64_t h_0;
    logos_shapes_Reflect_request_H_TU1_t h_1;
    logos_schema_commitment_t i;
    logos_tuple_size_0_t j;
    logos_bstr_size_0_t l;
    int8_t m;
    uint16_t n;
    logos_shapes_Counter_t o;
    logos_error_code_t p;
    bool has_q;
    logos_error_detail_t q;
    logos_shapes_Names_t r;
    const uint8_t* s;
    size_t s_len;
    const logos_shapes_Entry_t* t;
    size_t t_count;
    logos_shapes_Tree_t u;
    logos_shapes_Reflect_request_V_t v;
    logos_shapes_Blob_t y;
    logos_shapes_Digest_t z;
} reflect_in_t;

typedef struct {
    uint64_t a;
    int64_t b;
    const char* c;
    uint8_t d[32];
    logos_shapes_Reflect_response_E_LI_t* e;
    size_t e_count;
    logos_shapes_Reflect_response_F_LI_t* f;
    size_t f_count;
    logos_shapes_Reflect_response_G_t g;
    bool has_h;
    uint64_t h_0;
    logos_shapes_Reflect_response_H_TU1_t h_1;
    logos_schema_commitment_t i;
    logos_tuple_size_0_t j;
    logos_bstr_size_0_t l;
    int8_t m;
    uint16_t n;
    logos_shapes_Counter_t o;
    logos_error_code_t p;
    bool has_q;
    logos_error_detail_t q;
    logos_shapes_Names_t r;
    const uint8_t* s;
    size_t s_len;
    logos_shapes_Entry_t* t;
    size_t t_count;
    logos_shapes_Tree_t u;
    logos_shapes_Reflect_response_V_t v;
    logos_shapes_Blob_t y;
    logos_shapes_Digest_t z;
} reflect_out_t;


/* A request and the storage its pointers reach. */
typedef struct {
    reflect_in_t in;
    logos_shapes_Entry_t t[2];
    logos_shapes_Tree_t kid, left, twin_tree;
    logos_shapes_Pair_t pair;
    logos_shapes_Tree_t chain[TH_CHAIN];
} reflect_store_t;

static const logos_shapes_Reflect_request_E_LI_t E2[2] = {{{1, 2, 3, 4}}, {{5, 6, 7, 8}}};
static const logos_shapes_Reflect_request_F_LI_t F2[2] = {{1, "one"}, {2, "two"}};
static const uint8_t H2[2] = {0xAB, 0xCD};
static const uint8_t Q1[1] = {0x5A};
static const char* const NAMES[2] = {"ab", "cdefghij"}; /* the second at the 8-byte bound */
static const char* const LONG_NAMES[1] = {"much too long"};
static const uint8_t S3[3] = {0x00, 0xFF, 0x00};
static const char* const DIR_ENTRIES[1] = {"x"};
static const uint8_t Y2[2] = {0x10, 0x11};

static void leaf(logos_shapes_Tree_t* t)
{
    memset(t, 0, sizeof *t);
    t->tag = LOGOS_LITERAL_shapes_Leaf;
}

static void chain(reflect_store_t* st, int n)
{
    for (int k = 0; k < n; k++) {
        leaf(&st->chain[k]);
        if (k + 1 < n) {
            st->chain[k].has_left = true;
            st->chain[k].left = &st->chain[k + 1];
        }
    }
    st->in.u = st->chain[0];
}

static void reflect_full(reflect_store_t* st)
{
    reflect_in_t* in = &st->in;
    memset(in, 0, sizeof *in);
    in->a = LOGOS_LITERAL_shapes_Reflect_request_A;
    in->b = -42;
    in->c = "see";
    for (int k = 0; k < 32; k++)
        in->d[k] = (uint8_t)k;
    in->e = E2;
    in->e_count = 2;
    in->f = F2;
    in->f_count = 2;
    in->g.kind = LOGOS_ARM_shapes_Reflect_request_G_CASE_shapes_Value;
    in->g.value.arm_shapes_Value.kind = LOGOS_ARM_shapes_Value_CASE_Tstr;
    in->g.value.arm_shapes_Value.value.arm_Tstr = "gee";
    in->has_h = true;
    in->h_0 = 9;
    in->h_1.data = H2;
    in->h_1.len = 2;
    in->i.commitment_model = LOGOS_LITERAL_schema_commitment_Commitment_model;
    in->i.hash_profile = LOGOS_LITERAL_schema_commitment_Hash_profile;
    in->i.hash_suite = LOGOS_LITERAL_schema_commitment_Hash_suite;
    for (int k = 0; k < 32; k++)
        in->i.schema_root[k] = (uint8_t)(0xFF - k);
    in->m = -5;
    in->n = 65535;
    in->o = 42;
    in->p = LOGOS_ERR_TIMEOUT;
    in->has_q = true;
    in->q.data = Q1;
    in->q.len = 1;
    in->r.items = NAMES;
    in->r.count = 2;
    in->s = S3;
    in->s_len = 3;

    memset(st->t, 0, sizeof st->t);
    st->t[0].kind = LOGOS_ARM_shapes_Entry_CASE_File;
    st->t[0].value.arm_File.kind = LOGOS_LITERAL_shapes_Entry_AR_File_Kind;
    st->t[0].value.arm_File.path = "/f";
    st->t[1].kind = LOGOS_ARM_shapes_Entry_CASE_Dir;
    st->t[1].value.arm_Dir.kind = LOGOS_LITERAL_shapes_Entry_AR_Dir_Kind;
    st->t[1].value.arm_Dir.path = "/d";
    st->t[1].value.arm_Dir.entries = DIR_ENTRIES;
    st->t[1].value.arm_Dir.entries_count = 1;
    in->t = st->t;
    in->t_count = 2;

    leaf(&st->kid);
    leaf(&st->left);
    leaf(&st->twin_tree);
    st->pair.item_0 = &st->twin_tree;
    st->pair.item_1 = 77;
    leaf(&in->u);
    in->u.kids = &st->kid;
    in->u.kids_count = 1;
    in->u.has_left = true;
    in->u.left = &st->left;
    in->u.has_twin = true;
    in->u.twin = &st->pair;

    in->v.w = true;
    in->v.has_x = true;
    in->v.x = "ex";
    in->y.data = Y2;
    in->y.len = 2;
    in->z.data[0] = 9;
    in->z.data[1] = 8;
    in->z.data[2] = 7;
    in->z.data[3] = 6;
    in->j._empty = 0x55; /* ignored (INTERFACE §2.3) */
    in->l._empty = 0x55;
}

void th_shapes_reflect(const th_fns_t* f, logos_module_context_t* m, int variant,
                       th_report_t* rep)
{
    reflect_store_t* st = (reflect_store_t*)calloc(1, sizeof *st);
    if (st == NULL)
        abort();
    reflect_full(st);
    reflect_in_t* in = &st->in;

    const uint8_t(*pd)[32] = &in->d;
    const logos_shapes_Reflect_request_G_t* pg = &in->g;
    const logos_shapes_Reflect_request_H_TU1_t* ph1 = &in->h_1;
    const logos_error_detail_t* pq = &in->q;
    const logos_shapes_Tree_t* pu = &in->u;

    reflect_out_t o;
    memset(&o, 0, sizeof o);
    logos_shapes_Tree_t* pou = &o.u;
    logos_response_owner_t owner = {0};
    logos_response_owner_t* powner = &owner;

    switch (variant) {
    case TH_REFLECT_NULL_TEXT:
        in->c = NULL;
        break;
    case TH_REFLECT_BAD_KIND:
        in->g.kind = 7;
        break;
    case TH_REFLECT_NULL_LIST:
        in->e = NULL;
        break;
    case TH_REFLECT_BAD_UTF8:
        in->c = "\xff\xfe";
        break;
    case TH_REFLECT_LONG_NAME:
        in->r.items = LONG_NAMES;
        in->r.count = 1;
        break;
    case TH_REFLECT_WRONG_LITERAL:
        in->a = 8;
        break;
    case TH_REFLECT_CYCLE:
        in->u.kids = &in->u;
        break;
    case TH_REFLECT_FAILS:
        in->b = 13;
        break;
    case TH_REFLECT_BAD_RESPONSE:
        in->b = 14;
        break;
    case TH_REFLECT_DEEP:
        chain(st, 100);
        in->g.value.arm_shapes_Value.kind = LOGOS_ARM_shapes_Value_CASE_Bool;
        in->g.value.arm_shapes_Value.value.arm_Bool = true;
        break;
    case TH_REFLECT_NULL_ARRAY:
        pd = NULL;
        break;
    case TH_REFLECT_NULL_BYTES:
        in->q.data = NULL;
        break;
    case TH_REFLECT_ABSENT:
        in->has_h = false;
        ph1 = NULL;
        in->has_q = false;
        pq = NULL;
        in->v.has_x = false;
        in->v.x = NULL;
        leaf(&in->u);
        in->u.left = &in->u; /* ignored: has_left is false */
        memset(&in->g, 0, sizeof in->g);
        in->g.kind = LOGOS_ARM_shapes_Reflect_request_G_CASE_Tuple1;
        in->g.value.arm_Tuple1.item_0 = 5;
        break;
    case TH_REFLECT_EMPTY:
        in->e = NULL;
        in->e_count = 0;
        in->f = NULL;
        in->f_count = 0;
        in->r.items = NULL;
        in->r.count = 0;
        in->s = NULL;
        in->s_len = 0;
        in->t = NULL;
        in->t_count = 0;
        in->u.kids = NULL;
        in->u.kids_count = 0;
        memset(&in->g, 0, sizeof in->g);
        in->g.kind = LOGOS_ARM_shapes_Reflect_request_G_CASE_Tuple2;
        in->g.value.arm_Tuple2.item_0 = 3;
        in->g.value.arm_Tuple2.item_1 = 4;
        break;
    case TH_REFLECT_NULL_RECURSIVE:
        in->u.twin = NULL;
        break;
    case TH_REFLECT_BAD_CODE:
        in->p = (logos_error_code_t)99;
        break;
    case TH_REFLECT_NULL_OUTPUT:
        pou = NULL;
        break;
    case TH_REFLECT_NULL_STRUCT:
        pu = NULL;
        break;
    case TH_REFLECT_TOO_DEEP:
        chain(st, TH_CHAIN);
        break;
    case TH_REFLECT_DEEPEST:
        chain(st, TH_CHAIN - 1);
        break;
    case TH_REFLECT_BAD_ENTRY:
        st->t[1].kind = 2;
        break;
    case TH_REFLECT_NULL_OWNER:
        powner = NULL;
        break;
    case TH_REFLECT_NUMBERS:
        in->b = INT64_MIN;
        in->m = INT8_MIN;
        in->n = 0;
        in->o = UINT32_MAX;
        in->p = LOGOS_OK;
        in->g.value.arm_shapes_Value.kind = LOGOS_ARM_shapes_Value_CASE_Uint64;
        in->g.value.arm_shapes_Value.value.arm_Uint64 = UINT64_MAX;
        break;
    default:
        break;
    }

    logos_result_t r = f->shapes_reflect(
        m, powner, in->a, in->b, in->c, pd, in->e, in->e_count, in->f, in->f_count, pg,
        in->has_h, in->h_0, ph1, &in->i, &in->j, &in->l, in->m, in->n, in->o, in->p,
        in->has_q, pq, &in->r, in->s, in->s_len, in->t, in->t_count, pu, &in->v, &in->y,
        &in->z, &o.a, &o.b, &o.c, &o.d, &o.e, &o.e_count, &o.f, &o.f_count, &o.g,
        &o.has_h, &o.h_0, &o.h_1, &o.i, &o.j, &o.l, &o.m, &o.n, &o.o, &o.p, &o.has_q,
        &o.q, &o.r, &o.s, &o.s_len, &o.t, &o.t_count, pou, &o.v, &o.y, &o.z);
    finish(rep, r, owner, &o, sizeof o);
    sb_t b = sb_on(rep->text, sizeof rep->text);
    if (r.code == LOGOS_OK) {
        DUMP_REFLECT(&b, &o, response);
        rep->complete = b.nulls == 0;
        char* want = (char*)malloc(TH_TEXT);
        if (want == NULL)
            abort();
        sb_t w = sb_on(want, TH_TEXT);
        DUMP_REFLECT(&w, in, request);
        rep->same = strcmp(want, rep->text) == 0 && b.len + 1 < b.cap;
        free(want);
        /* An empty value's member reads as zero whatever the input held. */
        sbf(&b, " empty=%u/%u", (unsigned)o.j._empty, (unsigned)o.l._empty);
    }
    free(st);
}

/* A reflect call on a new thread with exactly `stack` bytes of stack: what a
 * provider entry needs at the payload depth limit (INTERFACE §4.5.1). Returns
 * nonzero when the thread could not be started. */
typedef struct {
    const th_fns_t* f;
    logos_module_context_t* m;
    int variant;
    th_report_t* rep;
} reflect_job_t;

#ifdef _WIN32
static DWORD WINAPI reflect_job(LPVOID p)
{
    reflect_job_t* j = (reflect_job_t*)p;
    th_shapes_reflect(j->f, j->m, j->variant, j->rep);
    return 0;
}

int th_shapes_reflect_on_stack(const th_fns_t* f, logos_module_context_t* m,
                               int variant, size_t stack, th_report_t* rep)
{
    reflect_job_t j = {f, m, variant, rep};
    HANDLE t = CreateThread(NULL, stack, reflect_job, &j,
                            STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
    if (t == NULL)
        return 1;
    WaitForSingleObject(t, INFINITE);
    CloseHandle(t);
    return 0;
}
#else
static void* reflect_job(void* p)
{
    reflect_job_t* j = (reflect_job_t*)p;
    th_shapes_reflect(j->f, j->m, j->variant, j->rep);
    return NULL;
}

int th_shapes_reflect_on_stack(const th_fns_t* f, logos_module_context_t* m,
                               int variant, size_t stack, th_report_t* rep)
{
    reflect_job_t j = {f, m, variant, rep};
    pthread_attr_t a;
    pthread_t t;
    if (pthread_attr_init(&a) != 0)
        return 1;
    int bad = pthread_attr_setstacksize(&a, stack) != 0 ||
              pthread_create(&t, &a, reflect_job, &j) != 0;
    pthread_attr_destroy(&a);
    if (bad)
        return 1;
    pthread_join(t, NULL);
    return 0;
}
#endif

/* One reflect call's outputs, kept with the call's owner. */
typedef struct {
    reflect_out_t o;
    logos_response_owner_t owner;
    logos_result_t r;
} reflect_call_t;

static void reflect_into(const th_fns_t* f, logos_module_context_t* m,
                         reflect_store_t* st, reflect_call_t* c)
{
    reflect_in_t* in = &st->in;
    memset(c, 0, sizeof *c);
    reflect_out_t* o = &c->o;
    c->r = f->shapes_reflect(
        m, &c->owner, in->a, in->b, in->c, &in->d, in->e, in->e_count, in->f,
        in->f_count, &in->g, in->has_h, in->h_0, &in->h_1, &in->i, &in->j, &in->l, in->m,
        in->n, in->o, in->p, in->has_q, &in->q, &in->r, in->s, in->s_len, in->t,
        in->t_count, &in->u, &in->v, &in->y, &in->z, &o->a, &o->b, &o->c, &o->d, &o->e,
        &o->e_count, &o->f, &o->f_count, &o->g, &o->has_h, &o->h_0, &o->h_1, &o->i, &o->j,
        &o->l, &o->m, &o->n, &o->o, &o->p, &o->has_q, &o->q, &o->r, &o->s, &o->s_len,
        &o->t, &o->t_count, &o->u, &o->v, &o->y, &o->z);
}

/* INTERFACE §2.7.1 from the caller's side: a full reflect's outputs read the
 * same after another call has run and been cleared; clearing the first owner
 * with the header's logos_response_owner_clear leaves the caller's output
 * objects as they were. `same` reports both; the owner comes back cleared. */
void th_shapes_reflect_cleared(const th_fns_t* f, logos_module_context_t* m,
                               th_report_t* rep)
{
    reflect_store_t* st = (reflect_store_t*)calloc(1, sizeof *st);
    reflect_call_t* first = (reflect_call_t*)calloc(1, sizeof *first);
    reflect_call_t* second = (reflect_call_t*)calloc(1, sizeof *second);
    char* again = (char*)malloc(TH_TEXT);
    if (st == NULL || first == NULL || second == NULL || again == NULL)
        abort();
    reflect_full(st);
    reflect_into(f, m, st, first);
    sb_t b = sb_on(rep->text, sizeof rep->text);
    rep->result = first->r;
    rep->owner = first->owner;
    rep->untouched = 0;
    rep->complete = 0;
    rep->same = 0;
    if (first->r.code == LOGOS_OK) {
        DUMP_REFLECT(&b, &first->o, response);
        rep->complete = b.nulls == 0;
        st->in.b = 7;
        st->in.c = "another";
        reflect_into(f, m, st, second);
        logos_response_owner_clear(&second->owner);
        sb_t w = sb_on(again, TH_TEXT);
        DUMP_REFLECT(&w, &first->o, response);
        int readable = second->r.code == LOGOS_OK && strcmp(again, rep->text) == 0;
        reflect_out_t before = first->o;
        logos_response_owner_clear(&first->owner);
        rep->owner = first->owner;
        rep->same = readable && memcmp(&before, &first->o, sizeof before) == 0 &&
                    first->owner.state == NULL && first->owner.release == NULL;
    }
    free(again);
    free(second);
    free(first);
    free(st);
}

/* shapes_module: pick and ping -------------------------------------------------- */

void th_shapes_pick(const th_fns_t* f, logos_module_context_t* m, int variant,
                    th_report_t* rep)
{
    logos_shapes_Pick_request_t req;
    memset(&req, 0, sizeof req);
    req.kind = LOGOS_ARM_shapes_Pick_request_CASE_Id;
    req.value.arm_Id.by = LOGOS_LITERAL_shapes_Pick_request_AR_Id_By;
    req.value.arm_Id.id = 5;
    switch (variant) {
    case TH_PICK_MISSING:
        req.value.arm_Id.id = 0;
        break;
    case TH_PICK_NAME:
        memset(&req, 0, sizeof req);
        req.kind = LOGOS_ARM_shapes_Pick_request_CASE_Name;
        req.value.arm_Name.by = LOGOS_LITERAL_shapes_Pick_request_AR_Name_By;
        req.value.arm_Name.name = "nm";
        break;
    case TH_PICK_BAD_KIND:
        req.kind = 9;
        break;
    case TH_PICK_WRONG_TAG:
        req.value.arm_Id.by = LOGOS_LITERAL_shapes_Pick_request_AR_Name_By;
        break;
    default:
        break;
    }
    logos_shapes_Pick_response_t out;
    memset(&out, 0, sizeof out);
    logos_response_owner_t owner = {0};
    logos_result_t r =
        f->shapes_pick(m, &owner, variant == TH_PICK_NULL ? NULL : &req, &out);
    finish(rep, r, owner, &out, sizeof out);
    sb_t b = sb_on(rep->text, sizeof rep->text);
    if (r.code != LOGOS_OK)
        return;
    switch (out.kind) {
    case LOGOS_ARM_shapes_Pick_response_CASE_False:
        sbf(&b, "found=%s", out.value.arm_False.found ? "true" : "false");
        break;
    case LOGOS_ARM_shapes_Pick_response_CASE_True:
        sbf(&b, "found=%s entry=", out.value.arm_True.found ? "true" : "false");
        dump_entry(&b, &out.value.arm_True.entry);
        break;
    default:
        sbf(&b, "?%u", (unsigned)out.kind);
    }
    rep->complete = b.nulls == 0;
}

void th_shapes_ping(const th_fns_t* f, logos_module_context_t* m, th_report_t* rep)
{
    logos_response_owner_t owner = {0};
    logos_result_t r = f->shapes_ping(m, &owner);
    finish(rep, r, owner, NULL, 0);
    sb_on(rep->text, sizeof rep->text);
    rep->complete = 1;
}

/* Typed cleanup (INTERFACE §2.7.2) ----------------------------------------------- */

/* One successful call, then its typed cleanup helper. `untouched` reports
 * that the owner and every output object then read as a {0} initializer
 * leaves them; `same` that a second cleanup of those locations, a cleanup of
 * a {0}-initialized set, and one of outputs full of garbage pointers beside
 * an empty owner (which only a helper that never reads through its outputs
 * survives) left everything zero. The result is the call's; the owner comes
 * back cleared. */
void th_typed_clear(const th_fns_t* f, logos_module_context_t* m, int which,
                    th_report_t* rep)
{
    logos_response_owner_t owner = {0};
    logos_response_owner_t fresh_owner = {0};
    sb_t b = sb_on(rep->text, sizeof rep->text);
    rep->untouched = 0;
    rep->complete = 0;
    rep->same = 0;
    switch (which) {
    case TH_CLEAR_READ: {
        meter_out_t o, z;
        memset(&o, 0, sizeof o);
        memset(&z, 0, sizeof z);
        rep->result = f->meter_read(m, &owner, 4, &o.label, &o.reading);
        if (rep->result.code != LOGOS_OK)
            break;
        sbf(&b, "label=");
        dump_text(&b, o.label);
        f->meter_read_clear(&owner, &o.label, &o.reading);
        rep->untouched = all_zero(&owner, sizeof owner) && all_zero(&o, sizeof o);
        f->meter_read_clear(&owner, &o.label, &o.reading);
        f->meter_read_clear(&fresh_owner, &z.label, &z.reading);
        rep->same = all_zero(&owner, sizeof owner) && all_zero(&o, sizeof o) &&
                    all_zero(&fresh_owner, sizeof fresh_owner) && all_zero(&z, sizeof z);
        memset(&z, 0xA5, sizeof z);
        f->meter_read_clear(&fresh_owner, &z.label, &z.reading);
        rep->same = rep->same && all_zero(&z, sizeof z);
        break;
    }
    case TH_CLEAR_REFLECT: {
        reflect_store_t* st = (reflect_store_t*)calloc(1, sizeof *st);
        reflect_call_t* c = (reflect_call_t*)calloc(1, sizeof *c);
        reflect_out_t* z = (reflect_out_t*)calloc(1, sizeof *z);
        if (st == NULL || c == NULL || z == NULL)
            abort();
        reflect_full(st);
        reflect_into(f, m, st, c);
        rep->result = c->r;
        if (c->r.code == LOGOS_OK) {
            DUMP_REFLECT(&b, &c->o, response);
            reflect_out_t* o = &c->o;
#define CLEAR_REFLECT(OWNER, O)                                                          \
    f->shapes_reflect_clear(                                                             \
        OWNER, &(O)->a, &(O)->b, &(O)->c, &(O)->d, &(O)->e, &(O)->e_count, &(O)->f,      \
        &(O)->f_count, &(O)->g, &(O)->has_h, &(O)->h_0, &(O)->h_1, &(O)->i, &(O)->j,     \
        &(O)->l, &(O)->m, &(O)->n, &(O)->o, &(O)->p, &(O)->has_q, &(O)->q, &(O)->r,      \
        &(O)->s, &(O)->s_len, &(O)->t, &(O)->t_count, &(O)->u, &(O)->v, &(O)->y, &(O)->z)
            CLEAR_REFLECT(&c->owner, o);
            rep->untouched =
                all_zero(&c->owner, sizeof c->owner) && all_zero(o, sizeof *o);
            CLEAR_REFLECT(&c->owner, o);
            CLEAR_REFLECT(&fresh_owner, z);
            rep->same = all_zero(&c->owner, sizeof c->owner) && all_zero(o, sizeof *o) &&
                        all_zero(&fresh_owner, sizeof fresh_owner) &&
                        all_zero(z, sizeof *z);
            /* Garbage in every payload pointer and count (the container's own
             * padding, between the output objects, is no output). */
            void* bad = (void*)(uintptr_t)0xA5A5A5A5u;
            z->c = (const char*)bad;
            z->e = (logos_shapes_Reflect_response_E_LI_t*)bad;
            z->e_count = 7;
            z->f = (logos_shapes_Reflect_response_F_LI_t*)bad;
            z->f_count = 7;
            z->has_h = true;
            z->h_1.data = (const uint8_t*)bad;
            z->h_1.len = 7;
            z->i.commitment_model = (const char*)bad;
            z->r.items = (const logos_tstr_size_1_8_t*)bad;
            z->r.count = 7;
            z->s = (const uint8_t*)bad;
            z->s_len = 7;
            z->t = (logos_shapes_Entry_t*)bad;
            z->t_count = 7;
            z->u.kids = (const logos_shapes_Tree_t*)bad;
            z->u.kids_count = 7;
            z->u.has_left = true;
            z->u.left = (const logos_shapes_Tree_t*)bad;
            z->u.tag = (const char*)bad;
            z->v.has_x = true;
            z->v.x = (const char*)bad;
            CLEAR_REFLECT(&fresh_owner, z);
            rep->same = rep->same && all_zero(z, sizeof *z);
#undef CLEAR_REFLECT
        }
        owner = c->owner;
        free(z);
        free(c);
        free(st);
        break;
    }
    case TH_CLEAR_PICK: {
        logos_shapes_Pick_request_t req;
        memset(&req, 0, sizeof req);
        req.kind = LOGOS_ARM_shapes_Pick_request_CASE_Name;
        req.value.arm_Name.by = LOGOS_LITERAL_shapes_Pick_request_AR_Name_By;
        req.value.arm_Name.name = "nm";
        logos_shapes_Pick_response_t out, z;
        memset(&out, 0, sizeof out);
        memset(&z, 0, sizeof z);
        rep->result = f->shapes_pick(m, &owner, &req, &out);
        if (rep->result.code != LOGOS_OK)
            break;
        if (out.kind == LOGOS_ARM_shapes_Pick_response_CASE_True) {
            sbf(&b, "entry=");
            dump_entry(&b, &out.value.arm_True.entry);
        }
        f->shapes_pick_clear(&owner, &out);
        rep->untouched = all_zero(&owner, sizeof owner) && all_zero(&out, sizeof out);
        f->shapes_pick_clear(&owner, &out);
        f->shapes_pick_clear(&fresh_owner, &z);
        rep->same = all_zero(&owner, sizeof owner) && all_zero(&out, sizeof out) &&
                    all_zero(&fresh_owner, sizeof fresh_owner) && all_zero(&z, sizeof z);
        memset(&z, 0xA5, sizeof z);
        f->shapes_pick_clear(&fresh_owner, &z);
        rep->same = rep->same && all_zero(&z, sizeof z);
        break;
    }
    default: {
        rep->result = f->shapes_ping(m, &owner);
        if (rep->result.code != LOGOS_OK)
            break;
        f->shapes_ping_clear(&owner);
        rep->untouched = all_zero(&owner, sizeof owner);
        f->shapes_ping_clear(&owner);
        f->shapes_ping_clear(&fresh_owner);
        rep->same = all_zero(&owner, sizeof owner) &&
                    all_zero(&fresh_owner, sizeof fresh_owner);
        break;
    }
    }
    rep->owner = owner;
    rep->complete = rep->result.code == LOGOS_OK && b.nulls == 0;
}
