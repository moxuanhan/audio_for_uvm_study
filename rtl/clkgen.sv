`timescale 1ns/1ps
module clkgen (
  input  logic       shubclk,
  input  logic       refclk,
  input  logic       rst_n,
  input  logic       c8_en,
  input  logic       c8_req,
  input  logic       dma_idle_all,
  input  logic       mclk_en,
  input  logic       sclk_en,
  input  logic [3:0] mclk_div,
  input  logic [3:0] sclk_div,
  output logic       dma_clk,
  output logic       mclk,
  output logic       sclk,
  output logic       c8_active
);
  logic c8_q;

  always_ff @(posedge shubclk or negedge rst_n) begin
    if (!rst_n)
      c8_q <= 1'b0;
    else if (c8_en && c8_req && dma_idle_all)
      c8_q <= 1'b1;
    else if (!dma_idle_all || !c8_req)
      c8_q <= 1'b0;
  end
  assign c8_active = c8_q;

  // shubclk(500M) -> refclk(100M) when C8 is entered
  assign dma_clk = c8_q ? refclk : shubclk;

  logic [7:0] mcnt, scnt;

  always_ff @(posedge dma_clk or negedge rst_n) begin
    if (!rst_n) begin
      mcnt <= '0;
      mclk <= 1'b0;
    end else if (mclk_en) begin
      if (mcnt >= {4'b0, mclk_div}) begin
        mcnt <= '0;
        mclk <= ~mclk;
      end else begin
        mcnt <= mcnt + 1'b1;
      end
    end
  end

  always_ff @(posedge dma_clk or negedge rst_n) begin
    if (!rst_n) begin
      scnt <= '0;
      sclk <= 1'b0;
    end else if (sclk_en) begin
      if (scnt >= {4'b0, sclk_div}) begin
        scnt <= '0;
        sclk <= ~sclk;
      end else begin
        scnt <= scnt + 1'b1;
      end
    end
  end
endmodule
