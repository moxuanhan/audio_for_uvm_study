`timescale 1ns/1ps
module tb_top;
  import audio_i2s_pkg::*;

  logic shubclk = 1'b0;
  logic refclk  = 1'b0;
  logic rst_n   = 1'b1;

  always #1 shubclk = ~shubclk; // 500 MHz
  always #5 refclk  = ~refclk;  // 100 MHz

  logic                       dma_clk;
  wire                        sclk;
  wire                        mclk;
  wire                        c8_active;
  wire                        dut_dma_clk;
  assign dma_clk = c8_active ? refclk : shubclk;
  wire [I2S_NUM-1:0]          sdata;
  wire [I2S_NUM-1:0]          lrck;
  wire [DMA_CH_NUM-1:0][31:0] dbg_level;
  wire [I2S_NUM-1:0][31:0]    dbg_i2s_word;

  // APB signals
  logic                  apb_psel;
  logic                  apb_penable;
  logic                  apb_pwrite;
  logic [APB_AW-1:0]     apb_paddr;
  logic [APB_DW-1:0]     apb_pwdata;
  wire                   apb_pready;
  wire [APB_DW-1:0]      apb_prdata;

  // AHB signals
  wire                   ahb_hsel;
  wire                   ahb_hwrite;
  wire [AHB_AW-1:0]      ahb_haddr;
  wire [AHB_DW-1:0]      ahb_hwdata;
  logic                  ahb_hready;
  logic                  ahb_hresp;
  logic [AHB_DW-1:0]     ahb_hrdata;

  logic [I2S_NUM-1:0][31:0] rx_word;

  audio_i2s_top dut (
    .shubclk(shubclk),
    .refclk(refclk),
    .rst_n(rst_n),
    .apb_psel(apb_psel),
    .apb_penable(apb_penable),
    .apb_pwrite(apb_pwrite),
    .apb_paddr(apb_paddr),
    .apb_pwdata(apb_pwdata),
    .apb_pready(apb_pready),
    .apb_prdata(apb_prdata),
    .ahb_hsel(ahb_hsel),
    .ahb_hwrite(ahb_hwrite),
    .ahb_haddr(ahb_haddr),
    .ahb_hwdata(ahb_hwdata),
    .ahb_hready(ahb_hready),
    .ahb_hresp(ahb_hresp),
    .ahb_hrdata(ahb_hrdata),
    .rx_word(rx_word),
    .sdata(sdata),
    .lrck(lrck),
    .sclk(sclk),
    .mclk(mclk),
    .c8_active(c8_active),
    .dma_clk(dut_dma_clk),
    .dbg_level(dbg_level),
    .dbg_i2s_word(dbg_i2s_word)
  );

  // ---- AHB slave memory model -----------------------------------------
  logic [31:0] mem [0:1023];

  initial begin
    for (int i = 0; i < 1024; i++)
      mem[i] = 32'hA000_0000 + i;
    for (int i = 0; i < I2S_NUM; i++)
      rx_word[i] = 32'hDEAD_BEEF + i;
  end

  always_ff @(posedge dma_clk or negedge rst_n) begin
    if (!rst_n) begin
      ahb_hready <= 1'b0;
      ahb_hresp  <= 1'b0;
      ahb_hrdata <= '0;
    end else begin
      ahb_hready <= 1'b0;
      ahb_hresp  <= 1'b0;
      if (ahb_hsel) begin
        if (!ahb_hwrite)
          ahb_hrdata <= mem[ahb_haddr[11:2]];
        else
          mem[ahb_haddr[11:2]] <= ahb_hwdata;
        ahb_hready <= 1'b1;
      end
    end
  end

  // ---- APB master tasks ------------------------------------------------
  task automatic apb_write(input logic [APB_AW-1:0] addr,
                           input logic [APB_DW-1:0] data);
    @(posedge shubclk);
    apb_psel = 1'b1;
    apb_pwrite = 1'b1;
    apb_paddr = addr;
    apb_pwdata = data;
    apb_penable = 1'b0;
    @(posedge shubclk);
    apb_penable = 1'b1;
    @(posedge shubclk);
    while (!apb_pready) @(posedge shubclk);
    apb_psel = 1'b0;
    apb_penable = 1'b0;
    apb_pwrite = 1'b0;
  endtask

  task automatic apb_read(input logic [APB_AW-1:0] addr,
                          output logic [APB_DW-1:0] data);
    @(posedge shubclk);
    apb_psel = 1'b1;
    apb_pwrite = 1'b0;
    apb_paddr = addr;
    apb_penable = 1'b0;
    @(posedge shubclk);
    apb_penable = 1'b1;
    @(posedge shubclk);
    while (!apb_pready) @(posedge shubclk);
    data = apb_prdata;
    apb_psel = 1'b0;
    apb_penable = 1'b0;
  endtask

  // ---- tests -----------------------------------------------------------
  int errors = 0;
  logic [31:0] status;

  initial begin : tests
    rst_n = 1'b1;
    repeat (2) @(posedge shubclk);
    rst_n = 1'b0;
    apb_psel = 1'b0;
    apb_penable = 1'b0;
    apb_pwrite = 1'b0;
    apb_paddr = '0;
    apb_pwdata = '0;
    ahb_hready = 1'b0;
    ahb_hresp = 1'b0;
    ahb_hrdata = '0;

    repeat (10) @(posedge shubclk);
    rst_n = 1'b1;
    repeat (5) @(posedge shubclk);

    // clkgen: mclk_en=1, sclk_en=1, div=3
    apb_write(12'h00C, 32'h0000_0033);

    $display("--- test_basic: CH0 / i2s0 TX ---");
    apb_write(12'h104, 32'h0000_0000); // src = 0
    apb_write(12'h10C, 32'h0000_0010); // 16 words
    apb_write(12'h100, 32'h0000_0001); // CH0 enable, TX
    apb_write(12'h300, 32'h0000_0041); // i2s0 enable, 4 slots
    repeat (500) @(posedge shubclk);
    if (dbg_i2s_word[0] == 32'h0) begin
      $display("ERR: i2s0 did not receive data");
      errors++;
    end else begin
      $display("i2s0 word = %h, level0 = %0d", dbg_i2s_word[0], dbg_level[0]);
    end

    $display("--- test_c8: CH1 / i2s1 TX ---");
    apb_write(12'h144, 32'h0000_0100); // src = 0x100
    apb_write(12'h14C, 32'h0000_1388); // 5000 words
    apb_write(12'h150, 32'h003E_0BB8); // low=1000, high=3000
    apb_write(12'h140, 32'h0000_0001); // CH1 enable, TX
    apb_write(12'h004, 32'h0000_0005); // c8_en + c8_req
    apb_write(12'h320, 32'h0000_0041); // i2s1 enable, 4 slots

    repeat (30000) @(posedge shubclk);
    apb_read(12'h008, status);
    $display("c8_status=%h c8_active=%b level1=%0d", status, c8_active, dbg_level[1]);
    if (!c8_active) begin
      $display("ERR: C8 was not entered");
      errors++;
    end
    apb_write(12'h004, 32'h0000_0001); // clear req -> exit C8
    repeat (2000) @(posedge shubclk);
    if (c8_active) begin
      $display("ERR: C8 did not exit");
      errors++;
    end
    apb_write(12'h100, 32'h0000_0000); // disable CH0
    apb_write(12'h140, 32'h0000_0000); // disable CH1

    $display("--- test_tdm_rx: i2s5 / CH5 RX ---");
    apb_write(12'h248, 32'h0000_0200); // dst = 0x200
    apb_write(12'h24C, 32'h0000_0010); // 16 words
    apb_write(12'h240, 32'h0000_0003); // CH5 enable, RX
    apb_write(12'h3A0, 32'h0000_0081); // i2s5 enable, 8 slots
    repeat (5000) @(posedge shubclk);
    if (mem[8'h80] == 32'hA000_0080) begin
      $display("ERR: RX path did not write memory");
      errors++;
    end else begin
      $display("RX mem[0x200] = %h", mem[8'h80]);
    end

    if (errors == 0)
      $display("ALL TESTS PASSED");
    else
      $display("TESTS FAILED: %0d", errors);
    $finish;
  end
endmodule
