// Three adders that must be logically identical, kept as a controlled
// comparison: two serial-carry designs and one parallel-prefix design.
// Used both as a standalone width study (SWEEP.md) and as the swappable
// carry-propagate block inside seg_add48 (rtl/mpmac.v).
module rca #(parameter W=8) (input [W-1:0] a, b, input cin, output [W-1:0] s, output cout);
  wire [W:0] c; assign c[0] = cin;
  genvar i;
  generate for (i = 0; i < W; i = i + 1) begin : bitgen
    assign s[i]   = a[i] ^ b[i] ^ c[i];
    assign c[i+1] = (a[i] & b[i]) | (c[i] & (a[i] ^ b[i]));
  end endgenerate
  assign cout = c[W];
endmodule

module cla #(parameter W=8) (input [W-1:0] a, b, input cin, output [W-1:0] s, output cout);
  wire [W-1:0] g = a & b;        // generate
  wire [W-1:0] p = a ^ b;        // propagate
  wire [W:0]   c; assign c[0] = cin;
  genvar i;
  generate for (i = 0; i < W; i = i + 1) begin : bitgen
    assign c[i+1] = g[i] | (p[i] & c[i]);
  end endgenerate
  assign s = p ^ c[W-1:0];
  assign cout = c[W];
endmodule

// Kogge-Stone: a REAL parallel-prefix adder. Carries come from a log-depth
// tree, not a serial chain -- this is the structure `cla` above only pretends
// to have. Cost: more gates. Benefit: depth grows as log2(W), not W.
module ksa #(parameter W=8) (input [W-1:0] a, b, input cin, output [W-1:0] s, output cout);
  localparam integer LG = $clog2(W);
  wire [W-1:0] g0 = a & b;
  wire [W-1:0] p0 = a ^ b;
  wire [(LG+1)*W-1:0] G, P;
  assign G[0*W +: W] = g0;
  assign P[0*W +: W] = p0;
  genvar k, i;
  generate
    for (k = 0; k < LG; k = k + 1) begin : stage
      for (i = 0; i < W; i = i + 1) begin : pos
        if (i >= (1<<k)) begin : combine
          assign G[(k+1)*W + i] = G[k*W+i] | (P[k*W+i] & G[k*W + i - (1<<k)]);
          assign P[(k+1)*W + i] = P[k*W+i] & P[k*W + i - (1<<k)];
        end else begin : passthru
          assign G[(k+1)*W + i] = G[k*W+i];
          assign P[(k+1)*W + i] = P[k*W+i];
        end
      end
    end
  endgenerate
  wire [W-1:0] Gf = G[LG*W +: W];
  wire [W-1:0] Pf = P[LG*W +: W];
  wire [W:0] c;
  assign c[0] = cin;
  generate for (i = 0; i < W; i = i + 1) begin : carry
    assign c[i+1] = Gf[i] | (Pf[i] & cin);
  end endgenerate
  assign s = p0 ^ c[W-1:0];
  assign cout = c[W];
endmodule
