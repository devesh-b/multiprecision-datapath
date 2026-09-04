// Self-checking testbench for the multi-precision MAC.
//
// The golden model here slices the operands and uses `*` directly. It shares
// no structure with the DUT's digit decomposition, which is the point: if the
// decomposition algebra is wrong, these two disagree.
//
// Stimulus classes, in the order that matters:
//   1. one-lane-hot        - the crosstalk case. Identical lanes cannot catch
//                            a leak, so every directed test drives ONE lane and
//                            asserts the others stay exactly zero.
//   2. negative products   - a negative lane result must not sign-extend past
//                            its own lane boundary.
//   3. exhaustive M4       - all 256 (a,b) digit pairs, per lane, both signs.
//   4. exhaustive M8 lane  - all 65536 8x8 pairs in one lane, other lane idle.
//   5. random M16/M8/M4    - full-width mixing.
//   6. overflow soak       - accumulate past the lane headroom (4 bits in M4)
//                            and confirm the carry stops at the lane boundary.

`timescale 1ns/1ps

module tb_mpmac;

  localparam M16 = 2'd0, M8 = 2'd1, M4 = 2'd2;

  reg         clk = 0, rst = 1, en = 0, sgn = 0;
  reg  [1:0]  mode = M16;
  reg  [15:0] a = 0, b = 0;
  wire [47:0] acc;

  reg  [47:0] exp;                 // expected accumulator, maintained here
  integer     errors = 0, checks = 0;

`ifndef DUT
 `define DUT mpmac_split
`endif
  `DUT dut (.clk(clk), .rst(rst), .en(en), .sgn(sgn),
            .mode(mode), .a(a), .b(b), .acc(acc));

  always #5 clk = ~clk;

  // ---- golden: slice the operands, extend to LANE width, multiply, add ----
  // Everything happens at the lane's own width, so a product that overflows
  // the natural product width (15*15 = 225 needs 8 unsigned bits) is never
  // silently re-interpreted as signed. That mistake is why this function is
  // written the long way instead of with narrow intermediates.
  function [47:0] golden;
    input [47:0] cur;
    input [15:0] ga, gb;
    input [1:0]  gm;
    input        gs;
    reg [47:0] xa, xb;
    reg [23:0] ya, yb;
    reg [11:0] za, zb;
    reg [47:0] r;
    integer L;
    begin
      case (gm)
        M16: begin
          xa = gs ? {{32{ga[15]}}, ga} : {32'b0, ga};
          xb = gs ? {{32{gb[15]}}, gb} : {32'b0, gb};
          golden = cur + (xa * xb);
        end
        M8: begin
          r = 48'd0;
          for (L = 0; L < 2; L = L + 1) begin
            ya = gs ? {{16{ga[8*L+7]}}, ga[8*L +: 8]} : {16'b0, ga[8*L +: 8]};
            yb = gs ? {{16{gb[8*L+7]}}, gb[8*L +: 8]} : {16'b0, gb[8*L +: 8]};
            r[24*L +: 24] = cur[24*L +: 24] + (ya * yb);
          end
          golden = r;
        end
        default: begin
          r = 48'd0;
          for (L = 0; L < 4; L = L + 1) begin
            za = gs ? {{8{ga[4*L+3]}}, ga[4*L +: 4]} : {8'b0, ga[4*L +: 4]};
            zb = gs ? {{8{gb[4*L+3]}}, gb[4*L +: 4]} : {8'b0, gb[4*L +: 4]};
            r[12*L +: 12] = cur[12*L +: 12] + (za * zb);
          end
          golden = r;
        end
      endcase
    end
  endfunction

  task automatic do_op;
    input [15:0] ta, tb_;
    input [1:0]  tm;
    input        ts;
    input [255:0] tag;
    begin
      a = ta; b = tb_; mode = tm; sgn = ts; en = 1;
      exp = golden(exp, ta, tb_, tm, ts);
      @(posedge clk);
      #1;
      checks = checks + 1;
      if (acc !== exp) begin
        errors = errors + 1;
        if (errors <= 15)
          $display("FAIL %0s mode=%0d sgn=%0d a=%h b=%h : acc=%h exp=%h",
                   tag, tm, ts, ta, tb_, acc, exp);
      end
    end
  endtask

  task automatic do_reset;
    begin
      en = 0; rst = 1; @(posedge clk); #1; rst = 0; exp = 48'd0;
      if (acc !== 48'd0) begin
        errors = errors + 1; $display("FAIL reset: acc=%h", acc);
      end
    end
  endtask

  integer av, bv, L, k, s, m, n;
  reg [15:0] ra, rb;

  initial begin
    @(posedge clk); rst = 0; exp = 48'd0; en = 0;

    // ---- 1 + 2: one-lane-hot and negative products, M4 --------------------
    for (s = 0; s <= 1; s = s + 1)
      for (L = 0; L < 4; L = L + 1) begin
        do_reset;
        // extreme values: signed -8 * -8 = +64, -8 * 7 = -56, unsigned 15*15
        do_op(16'h0008 << (4*L), 16'h0008 << (4*L), M4, s[0], "hot-8x8");
        do_op(16'h0008 << (4*L), 16'h0007 << (4*L), M4, s[0], "hot-8x7");
        do_op(16'h000F << (4*L), 16'h000F << (4*L), M4, s[0], "hot-FxF");
        do_op(16'h0007 << (4*L), 16'h0008 << (4*L), M4, s[0], "hot-7x8");
        // every other lane must still be exactly zero
        for (k = 0; k < 4; k = k + 1)
          if (k != L && acc[12*k +: 12] !== 12'd0) begin
            errors = errors + 1;
            $display("FAIL crosstalk M4: lane %0d dirty (%h) driving lane %0d, sgn=%0d",
                     k, acc[12*k +: 12], L, s[0]);
          end
      end

    // ---- 1 + 2 again for M8 ------------------------------------------------
    for (s = 0; s <= 1; s = s + 1)
      for (L = 0; L < 2; L = L + 1) begin
        do_reset;
        do_op(16'h0080 << (8*L), 16'h0080 << (8*L), M8, s[0], "hot8-80x80");
        do_op(16'h0080 << (8*L), 16'h007F << (8*L), M8, s[0], "hot8-80x7F");
        do_op(16'h00FF << (8*L), 16'h00FF << (8*L), M8, s[0], "hot8-FFxFF");
        for (k = 0; k < 2; k = k + 1)
          if (k != L && acc[24*k +: 24] !== 24'd0) begin
            errors = errors + 1;
            $display("FAIL crosstalk M8: lane %0d dirty (%h) driving lane %0d, sgn=%0d",
                     k, acc[24*k +: 24], L, s[0]);
          end
      end

    // ---- 3: exhaustive M4, all digit pairs, each lane in isolation ---------
    for (s = 0; s <= 1; s = s + 1)
      for (L = 0; L < 4; L = L + 1)
        for (av = 0; av < 16; av = av + 1)
          for (bv = 0; bv < 16; bv = bv + 1) begin
            do_reset;
            do_op(av[15:0] << (4*L), bv[15:0] << (4*L), M4, s[0], "exh-M4");
          end

    // ---- 3b: exhaustive M4 with all four lanes driven together ------------
    for (s = 0; s <= 1; s = s + 1)
      for (av = 0; av < 16; av = av + 1)
        for (bv = 0; bv < 16; bv = bv + 1) begin
          do_reset;
          do_op({4{av[3:0]}}, {4{bv[3:0]}}, M4, s[0], "exh-M4-all");
        end

    // ---- 4: exhaustive 8x8 in lane 0, lane 1 idle, then swapped -----------
    for (s = 0; s <= 1; s = s + 1)
      for (L = 0; L < 2; L = L + 1) begin
        do_reset;
        for (av = 0; av < 256; av = av + 1)
          for (bv = 0; bv < 256; bv = bv + 1)
            do_op(av[15:0] << (8*L), bv[15:0] << (8*L), M8, s[0], "exh-M8");
      end

    // ---- 5: random, all modes, mixed accumulation ------------------------
    for (s = 0; s <= 1; s = s + 1)
      for (m = 0; m < 3; m = m + 1) begin
        do_reset;
        for (n = 0; n < 200000; n = n + 1) begin
          ra = $random; rb = $random;
          do_op(ra, rb, m[1:0], s[0], "rand");
        end
      end

    // ---- 6: overflow soak. M4 headroom is 4 bits, so 15*15=225 overflows
    //         a 12-bit lane after 19 accumulations. Drive 64 and confirm the
    //         carry never leaves the lane.
    for (s = 0; s <= 1; s = s + 1)
      for (L = 0; L < 4; L = L + 1) begin
        do_reset;
        for (n = 0; n < 64; n = n + 1)
          do_op(16'h000F << (4*L), 16'h000F << (4*L), M4, s[0], "ovf-M4");
        for (k = 0; k < 4; k = k + 1)
          if (k != L && acc[12*k +: 12] !== 12'd0) begin
            errors = errors + 1;
            $display("FAIL overflow leak M4: lane %0d = %h after %0d accums in lane %0d",
                     k, acc[12*k +: 12], 64, L);
          end
      end
    // M8 headroom is 8 bits: 255*255=65025 overflows 24 bits after 258 accums.
    for (s = 0; s <= 1; s = s + 1)
      for (L = 0; L < 2; L = L + 1) begin
        do_reset;
        for (n = 0; n < 512; n = n + 1)
          do_op(16'h00FF << (8*L), 16'h00FF << (8*L), M8, s[0], "ovf-M8");
        for (k = 0; k < 2; k = k + 1)
          if (k != L && acc[24*k +: 24] !== 24'd0) begin
            errors = errors + 1;
            $display("FAIL overflow leak M8: lane %0d = %h in lane %0d", k,
                     acc[24*k +: 24], L);
          end
      end

    // ---- en=0 must hold the accumulator ------------------------------------
    do_reset;
    do_op(16'h1234, 16'h5678, M16, 1'b1, "hold-pre");
    begin
      reg [47:0] held; held = acc;
      en = 0; a = 16'hFFFF; b = 16'hFFFF; @(posedge clk); #1;
      checks = checks + 1;
      if (acc !== held) begin
        errors = errors + 1; $display("FAIL en=0 did not hold: %h != %h", acc, held);
      end
    end

    $display("");
    $display("checks: %0d   errors: %0d", checks, errors);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endmodule
