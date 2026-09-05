// Per-mode proof: in M8, the shared product network must equal 2
// dedicated 8x8 multiplier(s), each held in a 24-bit lane. This is the
// obligation BRIEF.md promised and DESIGN.md recorded as outstanding.
module miter_mode8 (input [15:0] a, b, input sgn);
  wire [47:0] prod;
  mpmac_shared u (.clk(1'b0), .rst(1'b1), .en(1'b0), .sgn(sgn),
                  .mode(2'd1), .a(a), .b(b), .acc(), .prod(prod));
  wire [23:0] za0 = sgn ? {{16{a[7]}}, a[0 +: 8]} : {16'b0, a[0 +: 8]};
  wire [23:0] zb0 = sgn ? {{16{b[7]}}, b[0 +: 8]} : {16'b0, b[0 +: 8]};
  wire [23:0] ex0 = za0 * zb0;
  wire [23:0] za1 = sgn ? {{16{a[15]}}, a[8 +: 8]} : {16'b0, a[8 +: 8]};
  wire [23:0] zb1 = sgn ? {{16{b[15]}}, b[8 +: 8]} : {16'b0, b[8 +: 8]};
  wire [23:0] ex1 = za1 * zb1;
  always @* begin
    assert (prod[0 +: 24] == ex0);
    assert (prod[24 +: 24] == ex1);
  end
endmodule
