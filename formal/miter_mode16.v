// Per-mode proof: in M16, the shared product network must equal 1
// dedicated 16x16 multiplier(s), each held in a 48-bit lane. This is the
// obligation BRIEF.md promised and DESIGN.md recorded as outstanding.
module miter_mode16 (input [15:0] a, b, input sgn);
  wire [47:0] prod;
  mpmac_shared u (.clk(1'b0), .rst(1'b1), .en(1'b0), .sgn(sgn),
                  .mode(2'd0), .a(a), .b(b), .acc(), .prod(prod));
  wire [47:0] za0 = sgn ? {{32{a[15]}}, a[0 +: 16]} : {32'b0, a[0 +: 16]};
  wire [47:0] zb0 = sgn ? {{32{b[15]}}, b[0 +: 16]} : {32'b0, b[0 +: 16]};
  wire [47:0] ex0 = za0 * zb0;
  always @* begin
    assert (prod[0 +: 48] == ex0);
  end
endmodule
