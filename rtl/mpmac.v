// Multi-precision MAC.
//
// One 16x16 datapath, three runtime modes, one 48-bit accumulator file that is
// PARTITIONED per mode, not replicated:
//
//   mode  lanes  operands   product  lane acc  headroom
//   M16     1    16 x 16    32 bit    48 bit    16 bit
//   M8      2     8 x  8    16 bit    24 bit     8 bit
//   M4      4     4 x  4     8 bit    12 bit     4 bit
//
// Every mode uses the same 16 sub-products a_i*b_j over 4-bit digits. Only the
// enable mask, the weights and the lane boundaries change. Signedness is
// handled by sign-extending ONLY the top digit of each lane, which is exactly
// what two's complement means:  A = sum_{i<top} a_i*2^4i + a~_top * 2^4top.
//
// Golden model and the proof of that algebra: model/mpmac.py.
//
// This file holds two variants that must be logically identical:
//   mpmac_split   V1 - three product networks + three accumulator adders,
//                      mux at the output. Only the sub-multipliers are shared.
//   mpmac_shared  V2 - one masked placement network and ONE segmented adder
//                      chain; mode drives only the enable masks and three
//                      carry-break gates.

`define MODE_M16 2'd0
`define MODE_M8  2'd1
`define MODE_M4  2'd2

// ---------------------------------------------------------------------------
// Shared front end: 4-bit digits -> 16 signed sub-products.
// Identical hardware in every mode; only the sign-extension control moves.
// ---------------------------------------------------------------------------
module mp_frontend (
  input  wire [15:0]  a,
  input  wire [15:0]  b,
  input  wire [1:0]   mode,
  input  wire         sgn,
  output wire [159:0] pp        // 16 x 10-bit signed, pp[k] at k*10, k = 4*i+j
);
  wire [3:0] da [0:3];
  wire [3:0] db [0:3];
  wire       top [0:3];         // is digit i the MSD of its lane in this mode?
  wire signed [4:0] sa [0:3];
  wire signed [4:0] sb [0:3];

  genvar i, j;
  generate
    for (i = 0; i < 4; i = i + 1) begin : dig
      assign da[i] = a[4*i +: 4];
      assign db[i] = b[4*i +: 4];
      // M16: only digit 3.  M8: digits 1 and 3.  M4: every digit.
      assign top[i] = (mode == `MODE_M16) ? ((i == 3)      ? 1'b1 : 1'b0) :
                      (mode == `MODE_M8 ) ? (((i & 1) == 1) ? 1'b1 : 1'b0) : 1'b1;
      assign sa[i] = (sgn & top[i]) ? {da[i][3], da[i]} : {1'b0, da[i]};
      assign sb[i] = (sgn & top[i]) ? {db[i][3], db[i]} : {1'b0, db[i]};
    end
    for (i = 0; i < 4; i = i + 1) begin : row
      for (j = 0; j < 4; j = j + 1) begin : col
        // range is -120 .. +225 (checked exhaustively in model/mpmac.py)
        assign pp[(4*i + j)*10 +: 10] = sa[i] * sb[j];
      end
    end
  endgenerate
endmodule

// ---------------------------------------------------------------------------
// V1: mpmac_split
// Three independent product networks and three independent accumulator adder
// sets. Mode selects which result is written back. Duplicates the reduction
// logic; the sub-multipliers are the only shared part.
// ---------------------------------------------------------------------------
module mpmac_split (
  input  wire        clk,
  input  wire        rst,
  input  wire        en,
  input  wire        sgn,
  input  wire [1:0]  mode,
  input  wire [15:0] a,
  input  wire [15:0] b,
  output wire [47:0] acc
);
  reg [47:0] q;
  assign acc = q;

  wire [159:0] pp;
  mp_frontend fe (.a(a), .b(b), .mode(mode), .sgn(sgn), .pp(pp));

  // 48-bit sign-extended view of sub-product k
  function [47:0] ext48; input [9:0] v; ext48 = {{38{v[9]}}, v}; endfunction
  function [23:0] ext24; input [9:0] v; ext24 = {{14{v[9]}}, v}; endfunction
  function [11:0] ext12; input [9:0] v; ext12 = {{ 2{v[9]}}, v}; endfunction

  integer i, j;

  // --- M16: all 16 terms, weight 4*(i+j), one 48-bit lane -------------------
  reg [47:0] p16;
  always @* begin
    p16 = 48'd0;
    for (i = 0; i < 4; i = i + 1)
      for (j = 0; j < 4; j = j + 1)
        p16 = p16 + (ext48(pp[(4*i+j)*10 +: 10]) << (4*(i+j)));
  end

  // --- M8: two lanes, terms with both digits in the same half ---------------
  reg [23:0] p8 [0:1];
  integer L;
  always @* begin
    for (L = 0; L < 2; L = L + 1) begin
      p8[L] = 24'd0;
      for (i = 0; i < 2; i = i + 1)
        for (j = 0; j < 2; j = j + 1)
          p8[L] = p8[L] + (ext24(pp[(4*(2*L+i) + (2*L+j))*10 +: 10]) << (4*(i+j)));
    end
  end

  // --- M4: four lanes, diagonal terms only -----------------------------------
  wire [11:0] p4 [0:3];
  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : m4lane
      assign p4[g] = {{2{pp[(4*g+g)*10 + 9]}}, pp[(4*g+g)*10 +: 10]};
    end
  endgenerate

  // --- accumulate: lane-local adds, so carries cannot cross a lane ----------
  wire [47:0] n16 = q + p16;
  wire [47:0] n8  = {q[47:24] + p8[1], q[23:0] + p8[0]};
  wire [47:0] n4  = {q[47:36] + p4[3], q[35:24] + p4[2],
                     q[23:12] + p4[1], q[11:0]  + p4[0]};

  wire [47:0] nxt = (mode == `MODE_M16) ? n16 :
                    (mode == `MODE_M8 ) ? n8  : n4;

  always @(posedge clk) begin
    if (rst)     q <= 48'd0;
    else if (en) q <= nxt;
  end
endmodule

// ---------------------------------------------------------------------------
// Segmented 48-bit adder: four 12-bit blocks whose carry chain is broken at
// the lane boundaries. This is the ONLY place mode touches the adder, and it
// costs exactly three AND gates.
//
//   M16  one 48-bit lane   -> merge b0-b1, b1-b2, b2-b3
//   M8   two 24-bit lanes  -> merge b0-b1 and b2-b3, break b1-b2
//   M4   four 12-bit lanes -> break everything
// ---------------------------------------------------------------------------
module seg_add48 #(
  parameter integer CPA = 0        // 0 = infer `+`, 1 = rca, 2 = ksa (rtl/adders.v)
) (
  input  wire [47:0] x,
  input  wire [47:0] y,
  input  wire [1:0]  mode,
  output wire [47:0] s
);
  // Decoded positively, not by excluding M4: the 2-bit mode field has an
  // unused code (2'b11) and "!= M4" would silently give it M8 lane merging
  // while the placement network gives it M4 terms. eqy found exactly that.
  // Both variants now treat any unused code as M4.
  wire m01 = (mode == `MODE_M16) | (mode == `MODE_M8);
  wire m12 = (mode == `MODE_M16);
  wire m23 = (mode == `MODE_M16) | (mode == `MODE_M8);

  wire [3:0]  cin, cout;
  wire [11:0] blk [0:3];

  assign cin[0] = 1'b0;
  assign cin[1] = m01 & cout[0];
  assign cin[2] = m12 & cout[1];
  assign cin[3] = m23 & cout[2];

  // The carry-propagate structure is swappable. Because the lanes are 12 / 24
  // / 48 bits wide depending on mode, ONE choice here has to serve all three
  // widths -- which is where "the optimum depends on operand width" stops
  // being a free win and becomes a real tension.
  genvar k;
  generate
    for (k = 0; k < 4; k = k + 1) begin : blkgen
      if (CPA == 1) begin : g_rca
        rca #(12) u (.a(x[12*k +: 12]), .b(y[12*k +: 12]), .cin(cin[k]),
                     .s(blk[k]), .cout(cout[k]));
      end else if (CPA == 2) begin : g_ksa
        ksa #(12) u (.a(x[12*k +: 12]), .b(y[12*k +: 12]), .cin(cin[k]),
                     .s(blk[k]), .cout(cout[k]));
      end else begin : g_inf
        wire [12:0] r = {1'b0, x[12*k +: 12]} + {1'b0, y[12*k +: 12]}
                      + {12'd0, cin[k]};
        assign blk[k]  = r[11:0];
        assign cout[k] = r[12];
      end
    end
  endgenerate

  assign s = {blk[3], blk[2], blk[1], blk[0]};
endmodule

// ---------------------------------------------------------------------------
// V2: mpmac_shared
// One placement network and one adder tree serve every mode. A sub-product is
// masked off when its two digits are not in the same lane, sign-extended only
// to the top of its own lane, and dropped into a 48-bit field by constant
// wiring (a 3:1 mux of pre-wired placements, not a barrel shifter).
//
// Mode drives exactly two things: the masks, and the three carry-break gates
// in seg_add48. Nothing else is duplicated.
// ---------------------------------------------------------------------------
module mpmac_shared #(
  parameter integer CPA = 0
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        en,
  input  wire        sgn,
  input  wire [1:0]  mode,
  input  wire [15:0] a,
  input  wire [15:0] b,
  output wire [47:0] acc
);
  reg [47:0] q;
  assign acc = q;

  wire [159:0] pp;
  mp_frontend fe (.a(a), .b(b), .mode(mode), .sgn(sgn), .pp(pp));

  wire [47:0] term [0:15];

  genvar i, j;
  generate
    for (i = 0; i < 4; i = i + 1) begin : trow
      for (j = 0; j < 4; j = j + 1) begin : tcol
        localparam integer K   = 4*i + j;
        localparam integer L8  = i / 2;                 // M8 lane of this term
        localparam integer OK8 = ((i/2) == (j/2));      // enabled in M8?
        localparam integer OK4 = (i == j);              // enabled in M4?

        wire [9:0]  p    = pp[K*10 +: 10];
        wire        sbit = p[9];

        // M16: one 48-bit lane, weight 4*(i+j)
        wire [47:0] t16 = {{38{sbit}}, p} << (4*(i+j));
        // M8: sign-extend inside 24 bits, weight 4*(i+j-4L), then place at 24L
        // shift amount is only meaningful when the term is in-lane; guard it
        // so a masked-off term never elaborates a negative shift
        localparam integer SH8 = OK8 ? (4*(i + j - 4*L8)) : 0;
        wire [23:0] v8  = {{14{sbit}}, p} << SH8;
        wire [47:0] t8  = OK8 ? ({24'd0, v8} << (24*L8)) : 48'd0;
        // M4: diagonal only, sign-extend inside 12 bits, place at 12i
        wire [11:0] v4  = {{2{sbit}}, p};
        wire [47:0] t4  = OK4 ? ({36'd0, v4} << (12*i)) : 48'd0;

        assign term[K] = (mode == `MODE_M16) ? t16 :
                         (mode == `MODE_M8 ) ? (OK8 ? t8 : 48'd0) : t4;
      end
    end
  endgenerate

  // Balanced tree of segmented adders: 16 terms -> 8 -> 4 -> 2 -> 1, then acc.
  wire [47:0] l1 [0:7];
  wire [47:0] l2 [0:3];
  wire [47:0] l3 [0:1];
  wire [47:0] l4;
  wire [47:0] nxt;

  genvar k;
  generate
    for (k = 0; k < 8; k = k + 1) begin : lev1
      seg_add48 #(CPA) u (.x(term[2*k]), .y(term[2*k+1]), .mode(mode), .s(l1[k]));
    end
    for (k = 0; k < 4; k = k + 1) begin : lev2
      seg_add48 #(CPA) u (.x(l1[2*k]), .y(l1[2*k+1]), .mode(mode), .s(l2[k]));
    end
    for (k = 0; k < 2; k = k + 1) begin : lev3
      seg_add48 #(CPA) u (.x(l2[2*k]), .y(l2[2*k+1]), .mode(mode), .s(l3[k]));
    end
  endgenerate
  seg_add48 #(CPA) u4  (.x(l3[0]), .y(l3[1]), .mode(mode), .s(l4));
  seg_add48 #(CPA) uac (.x(l4),    .y(q),     .mode(mode), .s(nxt));

  always @(posedge clk) begin
    if (rst)     q <= 48'd0;
    else if (en) q <= nxt;
  end
endmodule

// ---------------------------------------------------------------------------
// Mode-locked wrapper. Tying `mode` to a constant lets synthesis specialise the
// design to one lane width, which is how the per-mode area/depth numbers in
// DESIGN.md are produced: M16 exercises a 48-bit carry chain, M8 a 24-bit one,
// M4 a 12-bit one -- three widths out of one physical design.
// ---------------------------------------------------------------------------
module mpmac_locked #(
  parameter integer CPA  = 0,
  parameter [1:0]   MODE = `MODE_M16
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        en,
  input  wire        sgn,
  input  wire [15:0] a,
  input  wire [15:0] b,
  output wire [47:0] acc
);
  mpmac_shared #(.CPA(CPA)) u (
    .clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(MODE),
    .a(a), .b(b), .acc(acc));
endmodule

// Named CPA variants. Distinct module names so the testbench (-DDUT=) and eqy
// can select one without parameter overrides.
module mpmac_rca (
  input wire clk, rst, en, sgn, input wire [1:0] mode,
  input wire [15:0] a, b, output wire [47:0] acc);
  mpmac_shared #(.CPA(1)) u (.clk(clk), .rst(rst), .en(en), .sgn(sgn),
                             .mode(mode), .a(a), .b(b), .acc(acc));
endmodule

module mpmac_ksa (
  input wire clk, rst, en, sgn, input wire [1:0] mode,
  input wire [15:0] a, b, output wire [47:0] acc);
  mpmac_shared #(.CPA(2)) u (.clk(clk), .rst(rst), .en(en), .sgn(sgn),
                             .mode(mode), .a(a), .b(b), .acc(acc));
endmodule
