`timescale 1ns/1ps
import audio_i2s_pkg::*;
module ahb_dma (
  input  logic                        hclk,
  input  logic                        rst_n,
  // AHB master ports
  output logic                        hsel,
  output logic                        hwrite,
  output logic [AHB_AW-1:0]           haddr,
  output logic [AHB_DW-1:0]           hwdata,
  input  logic                        hready,
  input  logic                        hresp,
  input  logic [AHB_DW-1:0]           hrdata,
  // configuration from APB registers
  input  logic [DMA_CH_NUM-1:0]       ch_en,
  input  logic [DMA_CH_NUM-1:0]       ch_dir,      // 0: TX(mem->fifo), 1: RX(fifo->mem)
  input  logic [DMA_CH_NUM-1:0][31:0] ch_src,
  input  logic [DMA_CH_NUM-1:0][31:0] ch_dst,
  input  logic [DMA_CH_NUM-1:0][31:0] ch_len,
  input  logic [DMA_CH_NUM-1:0][11:0] ch_high_wm,
  input  logic [DMA_CH_NUM-1:0][11:0] ch_low_wm,
  input  logic                        c8_en,
  input  logic                        c8_active,
  // C8 status
  output logic [DMA_CH_NUM-1:0]       dma_idle,
  output logic [DMA_CH_NUM-1:0]       intr_idle,
  // FIFO interface to I2S
  input  logic [DMA_CH_NUM-1:0]       fifo_pop,
  output logic [DMA_CH_NUM-1:0][31:0] fifo_rdata,
  output logic [DMA_CH_NUM-1:0]       fifo_rvalid,
  input  logic [DMA_CH_NUM-1:0]       fifo_wvalid,
  input  logic [DMA_CH_NUM-1:0][31:0] fifo_wdata,
  output logic [DMA_CH_NUM-1:0]       fifo_wready,
  output logic [DMA_CH_NUM-1:0][31:0] dbg_level
);
  logic [31:0] fifo [DMA_CH_NUM][FIFO_BIG];
  int          depth   [DMA_CH_NUM];
  int          wr_ptr  [DMA_CH_NUM];
  int          rd_ptr  [DMA_CH_NUM];
  int          level   [DMA_CH_NUM];
  logic [31:0] cur_addr[DMA_CH_NUM];
  int          remain  [DMA_CH_NUM];
  logic        need_ahb[DMA_CH_NUM];
  logic        loaded  [DMA_CH_NUM];
  logic        ahb_busy;
  int          grant;
  int          g;
  int          ch;

  initial begin
    for (ch = 0; ch < DMA_CH_NUM; ch++) begin
      depth[ch]    = (ch >= 1 && ch <= 4) ? FIFO_BIG : FIFO_SMALL;
      wr_ptr[ch]   = 0;
      rd_ptr[ch]   = 0;
      level[ch]    = 0;
      cur_addr[ch] = 0;
      remain[ch]   = 0;
    end
    ahb_busy = 1'b0;
    grant    = 0;
  end

  always_ff @(posedge hclk or negedge rst_n) begin
    if (!rst_n) begin
      ahb_busy <= 1'b0;
      grant    <= 0;
      hsel     <= 1'b0;
      hwrite   <= 1'b0;
      haddr    <= '0;
      hwdata   <= '0;
      for (int i = 0; i < DMA_CH_NUM; i++) begin
        wr_ptr[i]    <= 0;
        rd_ptr[i]    <= 0;
        level[i]     <= 0;
        cur_addr[i]  <= 0;
        remain[i]     <= 0;
        dma_idle[i]   <= 1'b0;
        intr_idle[i]  <= 1'b0;
        fifo_rvalid[i]<= 1'b0;
        fifo_rdata[i] <= '0;
        fifo_wready[i]<= 1'b1;
        need_ahb[i]   = 1'b0;
        loaded[i]     <= 1'b0;
      end
    end else begin
      // registered FIFO outputs and AHB request
      for (int i = 0; i < DMA_CH_NUM; i++) begin
        fifo_rvalid[i] <= (level[i] > 0);
        fifo_rdata[i]  <= fifo[i][rd_ptr[i] & (depth[i] - 1)];
        fifo_wready[i] <= (level[i] < depth[i]);
        need_ahb[i]    = ch_en[i] && !c8_active && (remain[i] > 0) &&
                         ((ch_dir[i] == 1'b0) ? (level[i] < depth[i]) : (level[i] > 0));
      end
      // load configuration on first enable (re-arm when disabled)
      for (int i = 0; i < DMA_CH_NUM; i++) begin
        if (ch_en[i] && !loaded[i]) begin
          cur_addr[i] <= ch_dir[i] ? ch_dst[i] : ch_src[i];
          remain[i]   <= ch_len[i] >> 2;
          loaded[i]   <= 1'b1;
        end else if (!ch_en[i]) begin
          loaded[i] <= 1'b0;
          remain[i] <= 0;
        end
      end

      // I2S consumes FIFO data
      for (int i = 0; i < DMA_CH_NUM; i++) begin
        if (fifo_pop[i] && level[i] > 0) begin
          rd_ptr[i] <= rd_ptr[i] + 1;
          level[i]  <= level[i] - 1;
        end
      end

      // I2S RX pushes data into FIFO
      for (int i = 0; i < DMA_CH_NUM; i++) begin
        if (fifo_wvalid[i] && fifo_wready[i]) begin
          fifo[i][wr_ptr[i] & (depth[i] - 1)] <= fifo_wdata[i];
          wr_ptr[i] <= wr_ptr[i] + 1;
          level[i]  <= level[i] + 1;
        end
      end

      // C8 watermark hysteresis: only CH1..CH4
      for (int i = 0; i < DMA_CH_NUM; i++) begin
        if (i >= 1 && i <= 4 && c8_en) begin
          if (level[i] >= ch_high_wm[i])
            dma_idle[i] <= 1'b1;
          else if (level[i] <= ch_low_wm[i])
            dma_idle[i] <= 1'b0;
        end else begin
          dma_idle[i] <= 1'b0;
        end
        intr_idle[i] <= dma_idle[i];
        dbg_level[i] <= level[i][31:0];
      end

      // AHB master sequencer
      if (!ahb_busy) begin
        for (int i = 0; i < DMA_CH_NUM; i++) begin
          if (!ahb_busy && need_ahb[i]) begin
            ahb_busy <= 1'b1;
            grant    <= i;
            hsel     <= 1'b1;
            hwrite   <= ch_dir[i];
            haddr    <= cur_addr[i];
            if (ch_dir[i])
              hwdata <= fifo[i][rd_ptr[i] & (depth[i] - 1)];
          end
        end
      end else begin
        if (hready) begin
          g = grant;
          if (ch_dir[g] == 1'b0) begin
            if (level[g] < depth[g]) begin
              fifo[g][wr_ptr[g] & (depth[g] - 1)] <= hrdata;
              wr_ptr[g] <= wr_ptr[g] + 1;
              level[g]  <= level[g] + 1;
            end
          end else begin
            if (level[g] > 0) begin
              rd_ptr[g] <= rd_ptr[g] + 1;
              level[g]  <= level[g] - 1;
            end
          end
          cur_addr[g] <= cur_addr[g] + 32'd4;
          remain[g]   <= (remain[g] > 0) ? (remain[g] - 1) : 0;
          hsel        <= 1'b0;
          ahb_busy    <= 1'b0;
        end
      end
    end
  end
endmodule
