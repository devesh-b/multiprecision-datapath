// Width-parameterised multi-precision MAC.
//
// The 16-bit design in mpmac.v is the verified reference; this generalises the
// same architecture so the shared-vs-dedicated verdict can be re-measured at
// 32 and 64 bits. That verdict came out negative at 16 bits, and the whole
// point of the width-dependence literature is that a result at one width does
// not transfer.
//
//   W      operands  digits  accumulator  lane widths        headroom
//   16     16/8/4      4        48         48 / 24 / 12      16 / 8 / 4
//   32     32/16/8     8        96         96 / 48 / 24      32 / 16 / 8
//   64     64/32/16   16       192        192 / 96 / 48      64 / 32 / 16
//
// Accumulator is 3W bits so headroom is W/lanes in every mode, matching the
// 16-bit design exactly. Sub-products are always 4x4 digits, so their count
// grows as (W/4)^2 -- 16, 64, 256 -- which is the cost the sweep is measuring.
`timescale 1ns/1ps

`define GMODE_FULL 2'd0
`define GMODE_HALF 2'd1
`define GMODE_QUAD 2'd2

module mpmac_gen #(
  parameter integer W = 16
) (
  input  wire            clk, rst, en, sgn,
  input  wire [1:0]      mode,
  input  wire [W-1:0]    a, b,
  output wire [3*W-1:0]  acc
);
  localparam integer NDIG = W / 4;          // 4-bit digits
  localparam integer ACCW = 3 * W;
  localparam integer BLK  = ACCW / 4;       // narrowest lane
  localparam integer NT   = NDIG * NDIG;    // sub-products

  // ---- digits and mode-dependent sign extension --------------------------
  wire [3:0] da [0:NDIG-1];
  wire [3:0] db [0:NDIG-1];
  wire       top [0:NDIG-1];
  wire signed [4:0] sa [0:NDIG-1];
  wire signed [4:0] sb [0:NDIG-1];

  genvar i, j, k, l;
  generate
    for (i = 0; i < NDIG; i = i + 1) begin : dig
      assign da[i] = a[4*i +: 4];
      assign db[i] = b[4*i +: 4];
      // top digit of its lane: NDIG per lane in FULL, NDIG/2 in HALF, NDIG/4 in QUAD
      assign top[i] = (mode == `GMODE_FULL) ? ((i == NDIG-1)            ? 1'b1 : 1'b0) :
                      (mode == `GMODE_HALF) ? ((i % (NDIG/2) == NDIG/2-1) ? 1'b1 : 1'b0)
                                            : ((i % (NDIG/4) == NDIG/4-1) ? 1'b1 : 1'b0);
      assign sa[i] = (sgn & top[i]) ? {da[i][3], da[i]} : {1'b0, da[i]};
      assign sb[i] = (sgn & top[i]) ? {db[i][3], db[i]} : {1'b0, db[i]};
    end
  endgenerate

  // ---- placed, masked sub-products ---------------------------------------
  wire [ACCW-1:0] term [0:NT-1];
  generate
    for (i = 0; i < NDIG; i = i + 1) begin : trow
      for (j = 0; j < NDIG; j = j + 1) begin : tcol
        localparam integer K   = NDIG*i + j;
        localparam integer DH  = NDIG/2;                 // digits per lane, HALF
        localparam integer DQ  = NDIG/4;                 // digits per lane, QUAD
        localparam integer LH  = i / DH;
        localparam integer LQ  = i / DQ;
        localparam integer OKH = ((i/DH) == (j/DH)) ? 1 : 0;
        localparam integer OKQ = ((i/DQ) == (j/DQ)) ? 1 : 0;
        localparam integer SHH = (OKH != 0) ? (4*(i + j - 2*DH*LH)) : 0;
        localparam integer SHQ = (OKQ != 0) ? (4*(i + j - 2*DQ*LQ)) : 0;

        wire signed [9:0] p = sa[i] * sb[j];
        wire              sb_ = p[9];

        wire [ACCW-1:0]   tf = {{(ACCW-10){sb_}}, p} << (4*(i+j));
        wire [ACCW/2-1:0] vh = {{(ACCW/2-10){sb_}}, p} << SHH;
        wire [ACCW-1:0]   th = (OKH != 0) ? ({{(ACCW/2){1'b0}}, vh} << ((ACCW/2)*LH)) : {ACCW{1'b0}};
        wire [BLK-1:0]    vq = {{(BLK-10){sb_}}, p} << SHQ;
        wire [ACCW-1:0]   tq = (OKQ != 0) ? ({{(ACCW-BLK){1'b0}}, vq} << (BLK*LQ)) : {ACCW{1'b0}};

        assign term[K] = (mode == `GMODE_FULL) ? tf :
                         (mode == `GMODE_HALF) ? th : tq;
      end
    end
  endgenerate

  // ---- segmented adder: four blocks, carries broken by mode ---------------
  function [ACCW-1:0] seg_add;
    input [ACCW-1:0] x, y;
    input [1:0]      m;
    reg [BLK:0] r0, r1, r2, r3;
    reg         m01, m12, m23;
    begin
      m01 = (m == `GMODE_FULL) | (m == `GMODE_HALF);
      m12 = (m == `GMODE_FULL);
      m23 = (m == `GMODE_FULL) | (m == `GMODE_HALF);
      r0 = {1'b0, x[0*BLK +: BLK]} + {1'b0, y[0*BLK +: BLK]};
      r1 = {1'b0, x[1*BLK +: BLK]} + {1'b0, y[1*BLK +: BLK]} + {{BLK{1'b0}}, (m01 & r0[BLK])};
      r2 = {1'b0, x[2*BLK +: BLK]} + {1'b0, y[2*BLK +: BLK]} + {{BLK{1'b0}}, (m12 & r1[BLK])};
      r3 = {1'b0, x[3*BLK +: BLK]} + {1'b0, y[3*BLK +: BLK]} + {{BLK{1'b0}}, (m23 & r2[BLK])};
      seg_add = {r3[BLK-1:0], r2[BLK-1:0], r1[BLK-1:0], r0[BLK-1:0]};
    end
  endfunction

  // balanced reduction over the NT terms, then the accumulate
  reg [ACCW-1:0] red;
  reg [ACCW-1:0] nxt;
  integer t;
  always @* begin
    red = {ACCW{1'b0}};
    for (t = 0; t < NT; t = t + 1)
      red = seg_add(red, term[t], mode);
    nxt = seg_add(red, q, mode);
  end

  reg [ACCW-1:0] q;
  always @(posedge clk) begin
    if (rst)     q <= {ACCW{1'b0}};
    else if (en) q <= nxt;
  end
  assign acc = q;
endmodule

// Dedicated per-format units: the baseline the shared design has to beat.
module mac_sep_gen #(
  parameter integer W = 16
) (
  input  wire           clk, rst, en, sgn,
  input  wire [1:0]     mode,
  input  wire [W-1:0]   a, b,
  output wire [3*W-1:0] acc
);
  localparam integer ACCW = 3*W;
  wire [ACCW-1:0]   yf;
  wire [ACCW/2-1:0] yh [0:1];
  wire [ACCW/4-1:0] yq [0:3];

  wire ef = en & (mode == `GMODE_FULL);
  wire eh = en & (mode == `GMODE_HALF);
  wire eq = en & (mode != `GMODE_FULL) & (mode != `GMODE_HALF);

  mac_unit_gen #(W,   ACCW)   uf (.clk(clk), .rst(rst), .en(ef), .sgn(sgn),
                                  .a(a), .b(b), .acc(yf));
  genvar g;
  generate
    for (g = 0; g < 2; g = g + 1) begin : half
      mac_unit_gen #(W/2, ACCW/2) u (.clk(clk), .rst(rst), .en(eh), .sgn(sgn),
        .a(a[(W/2)*g +: W/2]), .b(b[(W/2)*g +: W/2]), .acc(yh[g]));
    end
    for (g = 0; g < 4; g = g + 1) begin : quad
      mac_unit_gen #(W/4, ACCW/4) u (.clk(clk), .rst(rst), .en(eq), .sgn(sgn),
        .a(a[(W/4)*g +: W/4]), .b(b[(W/4)*g +: W/4]), .acc(yq[g]));
    end
  endgenerate

  assign acc = (mode == `GMODE_FULL) ? yf :
               (mode == `GMODE_HALF) ? {yh[1], yh[0]}
                                     : {yq[3], yq[2], yq[1], yq[0]};
endmodule

module mac_unit_gen #(
  parameter integer WW = 16, parameter integer AW = 48
) (
  input  wire          clk, rst, en, sgn,
  input  wire [WW-1:0] a, b,
  output wire [AW-1:0] acc
);
  wire signed [WW:0]     sa = sgn ? {a[WW-1], a} : {1'b0, a};
  wire signed [WW:0]     sb = sgn ? {b[WW-1], b} : {1'b0, b};
  wire signed [2*WW+1:0] p  = sa * sb;
  wire [AW-1:0] pe = {{(AW-2*WW-2){p[2*WW+1]}}, p};
  reg  [AW-1:0] q;
  assign acc = q;
  always @(posedge clk) begin
    if (rst)     q <= {AW{1'b0}};
    else if (en) q <= q + pe;
  end
endmodule

// Named width instances. Yosys asserts on `-chparam` when a parameterised
// module instantiates further parameterised modules, so the sweep selects a
// top by name rather than overriding a parameter.
module mpmac_gen16  (input wire clk,rst,en,sgn, input wire [1:0] mode,
  input wire [15:0] a,b, output wire [47:0]  acc);
  mpmac_gen #(16) u (.clk(clk),.rst(rst),.en(en),.sgn(sgn),.mode(mode),.a(a),.b(b),.acc(acc));
endmodule
module mpmac_gen32  (input wire clk,rst,en,sgn, input wire [1:0] mode,
  input wire [31:0] a,b, output wire [95:0]  acc);
  mpmac_gen #(32) u (.clk(clk),.rst(rst),.en(en),.sgn(sgn),.mode(mode),.a(a),.b(b),.acc(acc));
endmodule
module mpmac_gen64  (input wire clk,rst,en,sgn, input wire [1:0] mode,
  input wire [63:0] a,b, output wire [191:0] acc);
  mpmac_gen #(64) u (.clk(clk),.rst(rst),.en(en),.sgn(sgn),.mode(mode),.a(a),.b(b),.acc(acc));
endmodule
module mac_sep_gen16 (input wire clk,rst,en,sgn, input wire [1:0] mode,
  input wire [15:0] a,b, output wire [47:0]  acc);
  mac_sep_gen #(16) u (.clk(clk),.rst(rst),.en(en),.sgn(sgn),.mode(mode),.a(a),.b(b),.acc(acc));
endmodule
module mac_sep_gen32 (input wire clk,rst,en,sgn, input wire [1:0] mode,
  input wire [31:0] a,b, output wire [95:0]  acc);
  mac_sep_gen #(32) u (.clk(clk),.rst(rst),.en(en),.sgn(sgn),.mode(mode),.a(a),.b(b),.acc(acc));
endmodule
module mac_sep_gen64 (input wire clk,rst,en,sgn, input wire [1:0] mode,
  input wire [63:0] a,b, output wire [191:0] acc);
  mac_sep_gen #(64) u (.clk(clk),.rst(rst),.en(en),.sgn(sgn),.mode(mode),.a(a),.b(b),.acc(acc));
endmodule
