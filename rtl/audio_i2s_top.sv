`timescale 1ns/1ps
import audio_i2s_pkg::*;
module audio_i2s_top (
  input  logic                        shubclk,
  input  logic                        refclk,
  input  logic                        rst_n,
  // APB slave ports (clocked by shubclk)
  input  logic                        apb_psel,
  input  logic                        apb_penable,
  input  logic                        apb_pwrite,
  input  logic [APB_AW-1:0]           apb_paddr,
  input  logic [APB_DW-1:0]           apb_pwdata,
  output logic                        apb_pready,
  output logic [APB_DW-1:0]           apb_prdata,
  // AHB master ports (clocked by internal dma_clk)
  output logic                        ahb_hsel,
  output logic                        ahb_hwrite,
  output logic [AHB_AW-1:0]           ahb_haddr,
  output logic [AHB_DW-1:0]           ahb_hwdata,
  input  logic                        ahb_hready,
  input  logic                        ahb_hresp,
  input  logic [AHB_DW-1:0]           ahb_hrdata,
  // misc
  input  logic [I2S_NUM-1:0][31:0]    rx_word,
  output logic [I2S_NUM-1:0]          sdata,
  output logic [I2S_NUM-1:0]          lrck,
  output logic                        sclk,
  output logic                        mclk,
  output logic                        c8_active,
  output logic                        dma_clk,
  output logic [DMA_CH_NUM-1:0][31:0] dbg_level,
  output logic [I2S_NUM-1:0][31:0]    dbg_i2s_word
);
  logic [DMA_CH_NUM-1:0]       dma_idle;
  logic [DMA_CH_NUM-1:0]       intr_idle;
  logic [DMA_CH_NUM-1:0]       fifo_pop;
  logic [DMA_CH_NUM-1:0][31:0] fifo_rdata;
  logic [DMA_CH_NUM-1:0]       fifo_rvalid;
  logic [DMA_CH_NUM-1:0]       fifo_wvalid;
  logic [DMA_CH_NUM-1:0][31:0] fifo_wdata;
  logic [DMA_CH_NUM-1:0]       fifo_wready;
  logic [I2S_NUM-1:0]          i2s_busy;

  logic [31:0] ctrl_reg;
  logic [31:0] c8_ctrl;
  logic [31:0] c8_status;
  logic [31:0] clkgen_ctrl;
  logic [31:0] dma_ctrl [DMA_CH_NUM];
  logic [31:0] dma_src  [DMA_CH_NUM];
  logic [31:0] dma_dst  [DMA_CH_NUM];
  logic [31:0] dma_len  [DMA_CH_NUM];
  logic [31:0] dma_wm   [DMA_CH_NUM];
  logic [31:0] i2s_ctrl [I2S_NUM];
  logic [31:0] i2s_stat [I2S_NUM];

  int ch;
  int iid;

  assign apb_pready = 1'b1;

  // Pre-decode APB address in continuous assignments: Icarus does not handle
  // constant part-selects reliably inside always_* processes.
  wire [11:0] pa        = apb_paddr;
  wire        is_global = (pa < 12'h100);
  wire        is_dma    = (pa >= 12'h100) && (pa < 12'h280);
  wire        is_i2s    = (pa >= 12'h300) && (pa < 12'h3C0);
  wire [1:0]  glob_idx  = pa[3:2];
  wire [2:0]  dma_ch    = (pa - 12'h100) >> 6;
  wire [2:0]  dma_idx   = ((pa - 12'h100) >> 2) & 3'h7;
  wire [2:0]  i2s_id    = (pa - 12'h300) >> 5;
  wire [1:0]  i2s_idx   = ((pa - 12'h300) >> 2) & 2'h3;
  wire        c8_idle_any = |dma_idle[4:1];
  wire        c8_intr_any = |intr_idle[4:1];

  // ---- APB write -------------------------------------------------------
  always_ff @(posedge shubclk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_reg    <= '0;
      c8_ctrl     <= '0;
      clkgen_ctrl <= '0;
      for (int i = 0; i < DMA_CH_NUM; i++) begin
        dma_ctrl[i] <= '0;
        dma_src[i]  <= '0;
        dma_dst[i]  <= '0;
        dma_len[i]  <= '0;
        dma_wm[i]   <= '0;
      end
      for (int i = 0; i < I2S_NUM; i++) begin
        i2s_ctrl[i] <= '0;
      end
    end else if (apb_psel && apb_penable && apb_pwrite) begin
      ch  = dma_ch;
      iid = i2s_id;
      if (is_global) begin
        case (glob_idx)
          2'h0: ctrl_reg    <= apb_pwdata;
          2'h1: c8_ctrl     <= apb_pwdata;
          2'h3: clkgen_ctrl <= apb_pwdata;
          default: ;
        endcase
      end else if (is_dma) begin
        case (dma_idx)
          3'h0: dma_ctrl[ch] <= apb_pwdata;
          3'h1: dma_src[ch]  <= apb_pwdata;
          3'h2: dma_dst[ch]  <= apb_pwdata;
          3'h3: dma_len[ch]  <= apb_pwdata;
          3'h4: dma_wm[ch]   <= apb_pwdata;
          default: ;
        endcase
      end else if (is_i2s) begin
        case (i2s_idx)
          2'h0: i2s_ctrl[iid] <= apb_pwdata;
          default: ;
        endcase
      end
    end
  end

  // ---- APB read / status -----------------------------------------------
  always_comb begin
    c8_status = {29'b0, c8_active, c8_intr_any, c8_idle_any};
    for (int i = 0; i < I2S_NUM; i++)
      i2s_stat[i] = (i2s_busy[i] & 32'h1);
    apb_prdata = '0;
    if (is_global) begin
      case (glob_idx)
        2'h0: apb_prdata = ctrl_reg;
        2'h1: apb_prdata = c8_ctrl;
        2'h2: apb_prdata = c8_status;
        2'h3: apb_prdata = clkgen_ctrl;
        default: ;
      endcase
    end else if (is_dma) begin
      ch = dma_ch;
      case (dma_idx)
        3'h0: apb_prdata = dma_ctrl[ch];
        3'h1: apb_prdata = dma_src[ch];
        3'h2: apb_prdata = dma_dst[ch];
        3'h3: apb_prdata = dma_len[ch];
        3'h4: apb_prdata = dma_wm[ch];
        3'h5: apb_prdata = (dma_idle[ch] & 32'h1);
        default: ;
      endcase
    end else if (is_i2s) begin
      iid = i2s_id;
      case (i2s_idx)
        2'h0: apb_prdata = i2s_ctrl[iid];
        2'h1: apb_prdata = i2s_stat[iid];
        default: ;
      endcase
    end
  end

  // ---- clock generation ------------------------------------------------
  clkgen u_clkgen (
    .shubclk(shubclk),
    .refclk(refclk),
    .rst_n(rst_n),
    .c8_en(c8_ctrl[0]),
    .c8_req(c8_ctrl[2]),
    .dma_idle_all(|dma_idle[4:1]),
    .mclk_en(clkgen_ctrl[0]),
    .sclk_en(clkgen_ctrl[1]),
    .mclk_div(clkgen_ctrl[7:4]),
    .sclk_div(clkgen_ctrl[11:8]),
    .dma_clk(dma_clk),
    .mclk(mclk),
    .sclk(sclk),
    .c8_active(c8_active)
  );

  // ---- DMA config unpack ----------------------------------------------
  logic [DMA_CH_NUM-1:0]       ch_en;
  logic [DMA_CH_NUM-1:0]       ch_dir;
  logic [DMA_CH_NUM-1:0][31:0] ch_src;
  logic [DMA_CH_NUM-1:0][31:0] ch_dst;
  logic [DMA_CH_NUM-1:0][31:0] ch_len;
  logic [DMA_CH_NUM-1:0][11:0] ch_high_wm;
  logic [DMA_CH_NUM-1:0][11:0] ch_low_wm;

  always_comb begin
    for (int i = 0; i < DMA_CH_NUM; i++) begin
      ch_en[i]      = (dma_ctrl[i] & 32'h1) != 32'h0;
      ch_dir[i]     = ((dma_ctrl[i] >> 1) & 32'h1) != 32'h0;
      ch_src[i]     = dma_src[i];
      ch_dst[i]     = dma_dst[i];
      ch_len[i]     = dma_len[i];
      ch_high_wm[i] = (dma_wm[i] & 32'hFFF) & 32'hFFF;
      ch_low_wm[i]  = ((dma_wm[i] >> 12) & 32'hFFF) & 32'hFFF;
    end
  end

  ahb_dma u_dma (
    .hclk(dma_clk),
    .rst_n(rst_n),
    .hsel(ahb_hsel),
    .hwrite(ahb_hwrite),
    .haddr(ahb_haddr),
    .hwdata(ahb_hwdata),
    .hready(ahb_hready),
    .hresp(ahb_hresp),
    .hrdata(ahb_hrdata),
    .ch_en(ch_en),
    .ch_dir(ch_dir),
    .ch_src(ch_src),
    .ch_dst(ch_dst),
    .ch_len(ch_len),
    .ch_high_wm(ch_high_wm),
    .ch_low_wm(ch_low_wm),
    .c8_en(c8_ctrl[0]),
    .c8_active(c8_active),
    .dma_idle(dma_idle),
    .intr_idle(intr_idle),
    .fifo_pop(fifo_pop),
    .fifo_rdata(fifo_rdata),
    .fifo_rvalid(fifo_rvalid),
    .fifo_wvalid(fifo_wvalid),
    .fifo_wdata(fifo_wdata),
    .fifo_wready(fifo_wready),
    .dbg_level(dbg_level)
  );

  // ---- I2S instances ---------------------------------------------------
  for (genvar i = 0; i < I2S_NUM; i++) begin : g_i2s
    apb_i2s #(
      .ID(i),
      .IS_TX(i < 5),
      .MAX_SLOTS(8)
    ) u_i2s (
      .sclk(sclk),
      .rst_n(rst_n),
      .en(i2s_ctrl[i][0]),
      .slots(i2s_ctrl[i][7:4]),
      .data_req(fifo_pop[i]),
      .fifo_rdata(fifo_rdata[i]),
      .fifo_rvalid(fifo_rvalid[i]),
      .fifo_wdata(fifo_wdata[i]),
      .fifo_wvalid(fifo_wvalid[i]),
      .fifo_wready(fifo_wready[i]),
      .rx_word(rx_word[i]),
      .sdata(sdata[i]),
      .lrck(lrck[i]),
      .busy(i2s_busy[i]),
      .debug_word(dbg_i2s_word[i])
    );
  end
endmodule
