// Baselines for the multi-precision MAC. Same ports, same 48-bit packed
// accumulator view, same synthesis flow -- so the numbers are comparable.
//
//   mac_separate  B1: one dedicated MAC per format, all seven present at once.
//                     The cost of NO SHARING, and the number mpmac must beat.
//   mac_fixed16   B2: a single 16x16 MAC used at every precision. The cost of
//                     NO FLEXIBILITY -- correct everywhere, wasteful when narrow,
//                     and it cannot produce two results in one cycle at all.
//
// Written behaviourally with `*` on purpose: this is what you get if you do not
// hand-decompose, which is exactly the comparison worth making.

`define MODE_M16 2'd0
`define MODE_M8  2'd1
`define MODE_M4  2'd2

module mac_unit #(parameter W = 16, parameter ACCW = 48) (
  input  wire            clk,
  input  wire            rst,
  input  wire            en,
  input  wire            sgn,
  input  wire [W-1:0]    a,
  input  wire [W-1:0]    b,
  output wire [ACCW-1:0] acc
);
  wire signed [W:0]     sa = sgn ? {a[W-1], a} : {1'b0, a};
  wire signed [W:0]     sb = sgn ? {b[W-1], b} : {1'b0, b};
  wire signed [2*W+1:0] p  = sa * sb;
  wire [ACCW-1:0] pe = {{(ACCW-2*W-2){p[2*W+1]}}, p};

  reg [ACCW-1:0] q;
  assign acc = q;
  always @(posedge clk) begin
    if (rst)     q <= {ACCW{1'b0}};
    else if (en) q <= q + pe;
  end
endmodule

// ---- B1: one dedicated unit per format, seven accumulators ----------------
module mac_separate (
  input  wire        clk,
  input  wire        rst,
  input  wire        en,
  input  wire        sgn,
  input  wire [1:0]  mode,
  input  wire [15:0] a,
  input  wire [15:0] b,
  output wire [47:0] acc
);
  wire e16 = en & (mode == `MODE_M16);
  wire e8  = en & (mode == `MODE_M8);
  wire e4  = en & (mode != `MODE_M16) & (mode != `MODE_M8);

  wire [47:0] a16;
  wire [23:0] a8  [0:1];
  wire [11:0] a4  [0:3];

  mac_unit #(16, 48) u16 (.clk(clk), .rst(rst), .en(e16), .sgn(sgn),
                          .a(a), .b(b), .acc(a16));
  genvar g;
  generate
    for (g = 0; g < 2; g = g + 1) begin : lane8
      mac_unit #(8, 24) u (.clk(clk), .rst(rst), .en(e8), .sgn(sgn),
                           .a(a[8*g +: 8]), .b(b[8*g +: 8]), .acc(a8[g]));
    end
    for (g = 0; g < 4; g = g + 1) begin : lane4
      mac_unit #(4, 12) u (.clk(clk), .rst(rst), .en(e4), .sgn(sgn),
                           .a(a[4*g +: 4]), .b(b[4*g +: 4]), .acc(a4[g]));
    end
  endgenerate

  assign acc = (mode == `MODE_M16) ? a16 :
               (mode == `MODE_M8 ) ? {a8[1], a8[0]}
                                   : {a4[3], a4[2], a4[1], a4[0]};
endmodule

// ---- B2: one fixed 16x16 unit, no SIMD capability at all ------------------
module mac_fixed16 (
  input  wire        clk,
  input  wire        rst,
  input  wire        en,
  input  wire        sgn,
  input  wire [1:0]  mode,      // ignored: this unit has one mode
  input  wire [15:0] a,
  input  wire [15:0] b,
  output wire [47:0] acc
);
  wire _unused = &{1'b0, mode};
  mac_unit #(16, 48) u (.clk(clk), .rst(rst), .en(en), .sgn(sgn),
                        .a(a), .b(b), .acc(acc));
endmodule
