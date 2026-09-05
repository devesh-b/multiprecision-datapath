// Width-parameterised check of mpmac_gen against a golden model, and of the
// dedicated-unit baseline it is measured against. Random rather than
// exhaustive: at W=64 the space is not enumerable, and the failure modes this
// looks for -- lane boundaries, sign extension, carry containment -- show up in
// thousands of vectors rather than billions.
`timescale 1ns/1ps

`ifndef GW
 `define GW 16
`endif

module tb_gen;
  localparam W    = `GW;
  localparam ACCW = 3*W;
  localparam N    = 20000;

  reg clk = 0, rst = 1, en = 0, sgn = 0;
  reg [1:0] mode = 0;
  reg [W-1:0] a = 0, b = 0;
  wire [ACCW-1:0] acc_s, acc_d;

  mpmac_gen   #(W) shared (.clk(clk), .rst(rst), .en(en), .sgn(sgn),
                           .mode(mode), .a(a), .b(b), .acc(acc_s));
  mac_sep_gen #(W) dedic  (.clk(clk), .rst(rst), .en(en), .sgn(sgn),
                           .mode(mode), .a(a), .b(b), .acc(acc_d));

  always #5 clk = ~clk;

  reg [ACCW-1:0] exp, xa, xb, prod, lane;
  integer errs_s, errs_d, checks, m, s, n, lanes, ow, lw;

  // For each lane: extend the operand slice to the accumulator width, multiply,
  // add into that lane with wrap. Variable shifts and masks throughout, because
  // the lane width is not a constant.
  task automatic step;
    input [W-1:0] ta, tb_;
    integer L2;
    reg [ACCW-1:0] mask, lmask;
    begin
      a = ta; b = tb_; en = 1;
      mask  = ({ACCW{1'b1}}) >> (ACCW - ow);
      lmask = ({ACCW{1'b1}}) >> (ACCW - lw);
      for (L2 = 0; L2 < lanes; L2 = L2 + 1) begin
        xa = (({{(ACCW-W){1'b0}}, ta})  >> (ow*L2)) & mask;
        if (sgn && ((xa >> (ow-1)) & 1'b1)) xa = xa | ~mask;
        xb = (({{(ACCW-W){1'b0}}, tb_}) >> (ow*L2)) & mask;
        if (sgn && ((xb >> (ow-1)) & 1'b1)) xb = xb | ~mask;
        prod = xa * xb;
        lane = (((exp >> (lw*L2)) & lmask) + (prod & lmask)) & lmask;
        exp  = (exp & ~(lmask << (lw*L2))) | (lane << (lw*L2));
      end
      @(posedge clk); #1;
      checks = checks + 1;
      if (acc_s !== exp) begin
        errs_s = errs_s + 1;
        if (errs_s < 4) $display("FAIL shared    W=%0d mode=%0d sgn=%0d a=%h b=%h got=%h exp=%h",
                                 W, mode, sgn, ta, tb_, acc_s, exp);
      end
      if (acc_d !== exp) begin
        errs_d = errs_d + 1;
        if (errs_d < 4) $display("FAIL dedicated W=%0d mode=%0d sgn=%0d a=%h b=%h got=%h exp=%h",
                                 W, mode, sgn, ta, tb_, acc_d, exp);
      end
    end
  endtask

  reg [W-1:0] ra, rb;
  reg [63:0]  rnd;
  initial begin
    errs_s = 0; errs_d = 0; checks = 0;
    @(posedge clk); #1; rst = 0;
    for (s = 0; s <= 1; s = s + 1)
      for (m = 0; m < 3; m = m + 1) begin
        sgn = s[0]; mode = m[1:0];
        lanes = (m == 0) ? 1 : (m == 1) ? 2 : 4;
        ow    = W / lanes;
        lw    = ACCW / lanes;
        en = 0; rst = 1; @(posedge clk); #1; rst = 0;
        exp = {ACCW{1'b0}};
        for (n = 0; n < N; n = n + 1) begin
          rnd = {$random, $random}; ra = rnd[W-1:0];
          rnd = {$random, $random}; rb = rnd[W-1:0];
          step(ra, rb);
        end
      end
    $display("W=%0d  checks %0d  shared errors %0d  dedicated errors %0d",
             W, checks, errs_s, errs_d);
    if (errs_s == 0 && errs_d == 0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endmodule
