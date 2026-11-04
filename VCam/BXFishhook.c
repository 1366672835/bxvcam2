//
//  BXFishhook.c
//  按符号名重绑（与 fishhook 同算法；原版 0x3344d0 就是这套流程）
//    1. 遍历所有镜像，取 LC_SYMTAB / LC_DYSYMTAB / __LINKEDIT
//    2. 找 __la_symbol_ptr / __nl_symbol_ptr 段
//    3. 用 indirect symbol 索引查名字，命中就改写指针
//
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#include "BXFishhook.h"

#define BX_LAZY_SYMBOL_POINTERS     0x7
#define BX_NON_LAZY_SYMBOL_POINTERS 0x6

typedef struct {
    const char *name;
    void       *replacement;
    void      **replaced;
} BXRebinding;

static int bx_protect(void *addr, size_t size) {
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)0xFFF;
    uintptr_t end = ((uintptr_t)addr + size + 0xFFF) & ~(uintptr_t)0xFFF;
    kern_return_t kr = vm_protect(mach_task_self(), page, end - page, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return kr == KERN_SUCCESS;
}

static int bx_rebind_image(const struct mach_header_64 *hdr, intptr_t slide,
                           BXRebinding *list, size_t count, int *hits) {
    if (!hdr || hdr->magic != MH_MAGIC_64) return 0;

    const struct symtab_command   *symtab = NULL;
    const struct dysymtab_command *dysym  = NULL;
    const struct segment_command_64 *linkedit = NULL;

    const struct load_command *cmd = (const struct load_command *)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (cmd->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)cmd;
        } else if (cmd->cmd == LC_DYSYMTAB) {
            dysym = (const struct dysymtab_command *)cmd;
        } else if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, "__LINKEDIT") == 0) linkedit = seg;
        }
        cmd = (const struct load_command *)((const char *)cmd + cmd->cmdsize);
    }
    if (!symtab || !dysym || !linkedit) return 0;

    // symoff/stroff/indirectsymoff 都是「文件偏移」，
    // 必须用 vmaddr - fileoff 才能换算成内存地址（漏掉 fileoff 会读到非法内存 → 崩溃）
    intptr_t linkeditBaseAddr = (intptr_t)slide + (intptr_t)linkedit->vmaddr - (intptr_t)linkedit->fileoff;
    const char *linkeditBase = (const char *)linkeditBaseAddr;
    const struct nlist_64 *syms = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strtab = linkeditBase + symtab->stroff;
    const uint32_t *indirect = (const uint32_t *)(linkeditBase + dysym->indirectsymoff);
    uint32_t nsyms = symtab->nsyms;
    uint32_t strsize = symtab->strsize;

    // 遍历所有段里的指针表段
    cmd = (const struct load_command *)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            // arm64e：__DATA_CONST / __AUTH_CONST 里是指针签名，裸写会崩。
            // 只处理 initprot 明确可写的段，其余直接跳过（宁可 0 命中，也不能崩）。
            int segWritable = (seg->initprot & VM_PROT_WRITE) != 0;
            if (!segWritable) { cmd = (const struct load_command *)((const char *)cmd + cmd->cmdsize); continue; }
            const struct section_64 *sect = (const struct section_64 *)(seg + 1);
            for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
                uint32_t type = sect->flags & SECTION_TYPE;
                if (type != BX_LAZY_SYMBOL_POINTERS && type != BX_NON_LAZY_SYMBOL_POINTERS) continue;

                uint32_t count_ptrs = (uint32_t)(sect->size / sizeof(void *));
                uint32_t baseIndex = sect->reserved1;
                void **ptrs = (void **)(sect->addr + slide);

                for (uint32_t p = 0; p < count_ptrs; p++) {
                    if (baseIndex + p >= dysym->nindirectsyms) break;   // 越界保护
                    uint32_t symIndex = indirect[baseIndex + p];
                    if ((symIndex & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) != 0) continue;
                    if (symIndex >= nsyms) continue;

                    uint32_t strx = syms[symIndex].n_un.n_strx;
                    if (strx == 0 || strx >= strsize) continue;

                    const char *name = strtab + strx;
                    if (name[0] == '_') name++;            // 去掉前导下划线

                    for (size_t r = 0; r < count; r++) {
                        if (strcmp(name, list[r].name) != 0) continue;
                        if (!bx_protect(&ptrs[p], sizeof(void *))) continue;
                        if (list[r].replaced && *list[r].replaced == NULL) {
                            *list[r].replaced = ptrs[p];
                        }
                        ptrs[p] = list[r].replacement;
                        (*hits)++;
                        break;
                    }
                }
            }
        }
        cmd = (const struct load_command *)((const char *)cmd + cmd->cmdsize);
    }
    return 1;
}

int BXRebindSymbols(const char *name, void *replacement, void **replaced) {
    if (!name || !replacement) return 0;

    BXRebinding one = { name, replacement, replaced };
    int hits = 0;

    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        bx_rebind_image((const struct mach_header_64 *)h, slide, &one, 1, &hits);
    }
    return hits;
}
