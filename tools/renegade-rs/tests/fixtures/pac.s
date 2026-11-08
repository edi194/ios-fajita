// Every instruction class pacstrip rewrites or reports, plus a data-in-code region and HINT-space PAC
// instructions that must stay as they are. Assembled for arm64e by make.py.
    .text
    .globl _pac_all
    .p2align 2
_pac_all:
    pacibsp
    retaa
    retab
    braa x1, x2
    brab x3, x4
    braaz x5
    brabz x6
    blraa x7, x8
    blrab x9, x10
    blraaz x11
    blrabz x12
    ldraa x0, [x1, #8]
    ldraa x0, [x1, #-8]!
    ldraa x0, [x1, #-256]
    ldraa x0, [x1, #-4096]
    ldraa x0, [x1, #-512]!
    ldrab x2, [x3, #4088]
    ldrab x2, [x3, #248]!
    pacia x0, x1
    pacib x2, x3
    pacda x4, x5
    pacdb x6, x7
    autia x8, x9
    autib x10, x11
    autda x12, x13
    autdb x14, sp
    paciza x0
    pacizb x1
    pacdza x2
    pacdzb x3
    autiza x4
    autizb x5
    autdza x6
    autdzb x7
    xpaci x8
    xpacd x9
    pacga x0, x1, x2
    pacga x3, x4, sp
    fjcvtzs w0, d1
    autibsp
    xpaclri
    ret
    .p2align 2
    .data_region
    .long 0xd65f0bff
    .long 0xdac10000
    .end_data_region
    nop
