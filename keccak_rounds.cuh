// File generato da gen_rounds.py - non modificare a mano
#pragma once

#define FIRST_ROUND \
    c4 = XOR(c_C4, L9); \
    d0 = XOR(c4, c_R1C1); \
    d3 = XOR(c_C2, ROTL(c4, 1)); \
    b00 = XOR(c_S[0], d0); \
    b10 = c_B[10]; \
    b20 = c_B[20]; \
    b05 = ROTL(XOR(c_S[3], d3), 28); \
    b15 = c_B[15]; \
    b16 = ROTL(XOR(c_S[5], d0), 36); \
    b01 = c_B[1]; \
    b11 = c_B[11]; \
    b21 = ROTL(XOR(c_S[8], d3), 55); \
    b06 = ROTL(XOR(L9, c_D4), 20); \
    b07 = ROTL(XOR(c_S[10], d0), 3); \
    b17 = c_B[17]; \
    b02 = c_B[2]; \
    b12 = ROTL(d3, 25); \
    b22 = c_B[22]; \
    b23 = ROTL(d0, 41); \
    b08 = c_B[8]; \
    b18 = c_B[18]; \
    b03 = ROTL(d3, 21); \
    b13 = c_B[13]; \
    b14 = ROTL(d0, 18); \
    b24 = c_B[24]; \
    b09 = c_B[9]; \
    b19 = ROTL(d3, 56); \
    b04 = c_B[4]; \
    a00 = CHI(b00, b01, b02); \
    a01 = CHI(b01, b02, b03); \
    a02 = CHI(b02, b03, b04); \
    a03 = CHI(b03, b04, b00); \
    a04 = CHI(b04, b00, b01); \
    a05 = CHI(b05, b06, b07); \
    a06 = CHI(b06, b07, b08); \
    a07 = CHI(b07, b08, b09); \
    a08 = CHI(b08, b09, b05); \
    a09 = CHI(b09, b05, b06); \
    a10 = CHI(b10, b11, b12); \
    a11 = CHI(b11, b12, b13); \
    a12 = CHI(b12, b13, b14); \
    a13 = CHI(b13, b14, b10); \
    a14 = CHI(b14, b10, b11); \
    a15 = CHI(b15, b16, b17); \
    a16 = CHI(b16, b17, b18); \
    a17 = CHI(b17, b18, b19); \
    a18 = CHI(b18, b19, b15); \
    a19 = CHI(b19, b15, b16); \
    a20 = CHI(b20, b21, b22); \
    a21 = CHI(b21, b22, b23); \
    a22 = CHI(b22, b23, b24); \
    a23 = CHI(b23, b24, b20); \
    a24 = CHI(b24, b20, b21); \
    a00 = XOR(a00, c_RC[0]);

#define ROUND(rc) \
    c0 = XOR5(a00, a05, a10, a15, a20); \
    c1 = XOR5(a01, a06, a11, a16, a21); \
    c2 = XOR5(a02, a07, a12, a17, a22); \
    c3 = XOR5(a03, a08, a13, a18, a23); \
    c4 = XOR5(a04, a09, a14, a19, a24); \
    d0 = ROTL(c0, 1); \
    d1 = ROTL(c1, 1); \
    d2 = ROTL(c2, 1); \
    d3 = ROTL(c3, 1); \
    d4 = ROTL(c4, 1); \
    b00 = XOR3(a00, c4, d1); \
    b10 = ROTL(XOR3(a01, c0, d2), 1); \
    b20 = ROTL(XOR3(a02, c1, d3), 62); \
    b05 = ROTL(XOR3(a03, c2, d4), 28); \
    b15 = ROTL(XOR3(a04, c3, d0), 27); \
    b16 = ROTL(XOR3(a05, c4, d1), 36); \
    b01 = ROTL(XOR3(a06, c0, d2), 44); \
    b11 = ROTL(XOR3(a07, c1, d3), 6); \
    b21 = ROTL(XOR3(a08, c2, d4), 55); \
    b06 = ROTL(XOR3(a09, c3, d0), 20); \
    b07 = ROTL(XOR3(a10, c4, d1), 3); \
    b17 = ROTL(XOR3(a11, c0, d2), 10); \
    b02 = ROTL(XOR3(a12, c1, d3), 43); \
    b12 = ROTL(XOR3(a13, c2, d4), 25); \
    b22 = ROTL(XOR3(a14, c3, d0), 39); \
    b23 = ROTL(XOR3(a15, c4, d1), 41); \
    b08 = ROTL(XOR3(a16, c0, d2), 45); \
    b18 = ROTL(XOR3(a17, c1, d3), 15); \
    b03 = ROTL(XOR3(a18, c2, d4), 21); \
    b13 = ROTL(XOR3(a19, c3, d0), 8); \
    b14 = ROTL(XOR3(a20, c4, d1), 18); \
    b24 = ROTL(XOR3(a21, c0, d2), 2); \
    b09 = ROTL(XOR3(a22, c1, d3), 61); \
    b19 = ROTL(XOR3(a23, c2, d4), 56); \
    b04 = ROTL(XOR3(a24, c3, d0), 14); \
    a00 = CHI(b00, b01, b02); \
    a01 = CHI(b01, b02, b03); \
    a02 = CHI(b02, b03, b04); \
    a03 = CHI(b03, b04, b00); \
    a04 = CHI(b04, b00, b01); \
    a05 = CHI(b05, b06, b07); \
    a06 = CHI(b06, b07, b08); \
    a07 = CHI(b07, b08, b09); \
    a08 = CHI(b08, b09, b05); \
    a09 = CHI(b09, b05, b06); \
    a10 = CHI(b10, b11, b12); \
    a11 = CHI(b11, b12, b13); \
    a12 = CHI(b12, b13, b14); \
    a13 = CHI(b13, b14, b10); \
    a14 = CHI(b14, b10, b11); \
    a15 = CHI(b15, b16, b17); \
    a16 = CHI(b16, b17, b18); \
    a17 = CHI(b17, b18, b19); \
    a18 = CHI(b18, b19, b15); \
    a19 = CHI(b19, b15, b16); \
    a20 = CHI(b20, b21, b22); \
    a21 = CHI(b21, b22, b23); \
    a22 = CHI(b22, b23, b24); \
    a23 = CHI(b23, b24, b20); \
    a24 = CHI(b24, b20, b21); \
    a00 = XOR(a00, rc);

#define LAST_ROUND_A0 \
    c0 = XOR5(a00, a05, a10, a15, a20); \
    c1 = XOR5(a01, a06, a11, a16, a21); \
    c2 = XOR5(a02, a07, a12, a17, a22); \
    c3 = XOR5(a03, a08, a13, a18, a23); \
    c4 = XOR5(a04, a09, a14, a19, a24); \
    d1 = ROTL(c1, 1); \
    d2 = ROTL(c2, 1); \
    d3 = ROTL(c3, 1); \
    a00 = XOR(CHI(XOR3(a00, c4, d1), ROTL(XOR3(a06, c0, d2), 44), ROTL(XOR3(a12, c1, d3), 43)), c_RC[23]);

#define ROUNDS_1_22 \
    ROUND(make_uint2(0x0u, 0x89u)) \
    ROUND(make_uint2(0x0u, 0x8000008bu)) \
    ROUND(make_uint2(0x0u, 0x80008080u)) \
    ROUND(make_uint2(0x1u, 0x8bu)) \
    ROUND(make_uint2(0x1u, 0x8000u)) \
    ROUND(make_uint2(0x1u, 0x80008088u)) \
    ROUND(make_uint2(0x1u, 0x80000082u)) \
    ROUND(make_uint2(0x0u, 0xbu)) \
    ROUND(make_uint2(0x0u, 0xau)) \
    ROUND(make_uint2(0x1u, 0x8082u)) \
    ROUND(make_uint2(0x0u, 0x8003u)) \
    ROUND(make_uint2(0x1u, 0x808bu)) \
    ROUND(make_uint2(0x1u, 0x8000000bu)) \
    ROUND(make_uint2(0x1u, 0x8000008au)) \
    ROUND(make_uint2(0x1u, 0x80000081u)) \
    ROUND(make_uint2(0x0u, 0x80000081u)) \
    ROUND(make_uint2(0x0u, 0x80000008u)) \
    ROUND(make_uint2(0x0u, 0x83u)) \
    ROUND(make_uint2(0x0u, 0x80008003u)) \
    ROUND(make_uint2(0x1u, 0x80008088u)) \
    ROUND(make_uint2(0x0u, 0x80000088u)) \
    ROUND(make_uint2(0x1u, 0x8000u))

