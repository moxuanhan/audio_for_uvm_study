`timescale 1ns/1ps
module apb_i2s #(
  parameter int  ID        = 0,
  parameter bit  IS_TX     = 1,
  parameter int  MAX_SLOTS = 8
)(
  input  logic       sclk,
  input  logic       rst_n,
  input  logic       en,
  input  logic [3:0] slots,
  // FIFO handshake with DMA
  output logic       data_req,
  input  logic [31:0] fifo_rdata,
  input  logic        fifo_rvalid,
  output logic [31:0] fifo_wdata,
  output logic        fifo_wvalid,
  input  logic        fifo_wready,
  // parallel word from TB for RX mode
  input  logic [31:0] rx_word,
  // serial pins
  output logic        sdata,
  output logic        lrck,
  output logic        busy,
  output logic [31:0] debug_word
);
  logic [3:0]  slot_cnt;
  logic [31:0] shift;
  logic [3:0]  slot_limit;

  always_comb begin
    slot_limit = (slots == 4'd0) ? 4'd2 : slots;
    if (slot_limit > 4'd8) slot_limit = 4'd8;
  end

  always_ff @(posedge sclk or negedge rst_n) begin
    if (!rst_n) begin
      slot_cnt    <= '0;
      shift       <= '0;
      sdata       <= 1'b0;
      lrck        <= 1'b0;
      busy        <= 1'b0;
      data_req    <= 1'b0;
      fifo_wvalid <= 1'b0;
      fifo_wdata  <= '0;
      debug_word  <= '0;
    end else if (!en) begin
      busy        <= 1'b0;
      data_req    <= 1'b0;
      fifo_wvalid <= 1'b0;
    end else begin
      busy <= 1'b1;
      if (IS_TX) begin
        if (slot_cnt == 4'd0)
          data_req <= 1'b1;
        if (data_req && fifo_rvalid) begin
          shift      <= fifo_rdata;
          debug_word <= fifo_rdata;
          data_req   <= 1'b0;
        end
        sdata <= shift[31];
        shift <= {shift[30:0], 1'b0};
        if (slot_cnt >= slot_limit - 4'd1) begin
          slot_cnt <= '0;
          lrck     <= ~lrck;
        end else begin
          slot_cnt <= slot_cnt + 4'd1;
        end
      end else begin
        // RX (TDM): one parallel word is pushed per frame
        fifo_wvalid <= (slot_cnt == 4'd0);
        fifo_wdata  <= rx_word;
        if (slot_cnt >= slot_limit - 4'd1) begin
          slot_cnt <= '0;
          lrck     <= ~lrck;
        end else begin
          slot_cnt <= slot_cnt + 4'd1;
        end
      end
    end
  end
endmodule
