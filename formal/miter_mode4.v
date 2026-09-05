// Per-mode proof: in M4, the shared product network must equal 4
// dedicated 4x4 multiplier(s), each held in a 12-bit lane. This is the
// obligation BRIEF.md promised and DESIGN.md recorded as outstanding.
module miter_mode4 (input [15:0] a, b, input sgn);
  wire [47:0] prod;
  mpmac_shared u (.clk(1'b0), .rst(1'b1), .en(1'b0), .sgn(sgn),
                  .mode(2'd2), .a(a), .b(b), .acc(), .prod(prod));
  wire [11:0] za0 = sgn ? {{8{a[3]}}, a[0 +: 4]} : {8'b0, a[0 +: 4]};
  wire [11:0] zb0 = sgn ? {{8{b[3]}}, b[0 +: 4]} : {8'b0, b[0 +: 4]};
  wire [11:0] ex0 = za0 * zb0;
  wire [11:0] za1 = sgn ? {{8{a[7]}}, a[4 +: 4]} : {8'b0, a[4 +: 4]};
  wire [11:0] zb1 = sgn ? {{8{b[7]}}, b[4 +: 4]} : {8'b0, b[4 +: 4]};
  wire [11:0] ex1 = za1 * zb1;
  wire [11:0] za2 = sgn ? {{8{a[11]}}, a[8 +: 4]} : {8'b0, a[8 +: 4]};
  wire [11:0] zb2 = sgn ? {{8{b[11]}}, b[8 +: 4]} : {8'b0, b[8 +: 4]};
  wire [11:0] ex2 = za2 * zb2;
  wire [11:0] za3 = sgn ? {{8{a[15]}}, a[12 +: 4]} : {8'b0, a[12 +: 4]};
  wire [11:0] zb3 = sgn ? {{8{b[15]}}, b[12 +: 4]} : {8'b0, b[12 +: 4]};
  wire [11:0] ex3 = za3 * zb3;
  always @* begin
    assert (prod[0 +: 12] == ex0);
    assert (prod[12 +: 12] == ex1);
    assert (prod[24 +: 12] == ex2);
    assert (prod[36 +: 12] == ex3);
  end
endmodule
