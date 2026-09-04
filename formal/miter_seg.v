// Combinational miter: the three carry-propagate choices inside seg_add48 must
// compute the same sum in every mode. seg_add48 is the ONLY thing that differs
// between mpmac_shared, mpmac_rca and mpmac_ksa, so proving the block proves
// the three MACs equivalent by substitution -- and it is a depth-1 query
// instead of a 48-partition sequential one.
module miter_seg (input [47:0] x, y, input [1:0] mode);
  wire [47:0] s_inf, s_rca, s_ksa;
  seg_add48 #(0) u0 (.x(x), .y(y), .mode(mode), .s(s_inf));
  seg_add48 #(1) u1 (.x(x), .y(y), .mode(mode), .s(s_rca));
  seg_add48 #(2) u2 (.x(x), .y(y), .mode(mode), .s(s_ksa));
  always @* begin
    assert (s_inf == s_rca);
    assert (s_inf == s_ksa);
  end
endmodule
