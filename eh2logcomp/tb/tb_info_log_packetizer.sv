`timescale 1ns/1ps
module tb_info_log_packetizer;
  logic clk=0, resetn=0, start=0, hart=0;
  logic [31:0] total_records=47;
  logic [511:0] beat_data;
  logic beat_valid, beat_ready;
  logic [7:0] tdata;
  logic tvalid,tlast,tready=1,busy,done;
  integer beat_index=0, frame_index=0, byte_index=0;
  integer frame_length[0:2];
  logic [255:0] rec0, rec1;

  always #4 clk=~clk;
  always_comb begin
    rec0 = {(beat_index*2),224'b0};
    rec1 = {(beat_index*2+1),224'b0};
    beat_data = {rec1,rec0};
    beat_valid = (beat_index < 24);
  end
  always_ff @(posedge clk)
    if (resetn && beat_valid && beat_ready) beat_index <= beat_index+1;

  info_log_tx_packetizer dut(
    .clk,.resetn,.start,.hart,.total_records,.beat_data,.beat_valid,
    .beat_ready,.m_axis_tdata(tdata),.m_axis_tvalid(tvalid),
    .m_axis_tlast(tlast),.m_axis_tready(tready),.busy,.done);

  always_ff @(posedge clk) if (resetn && tvalid && tready) begin
    if (frame_index < 2 && byte_index >= 14 && byte_index < 1486) begin
      integer payload_byte, record_no, in_record;
      payload_byte = byte_index-14;
      record_no = frame_index*46 + payload_byte/32;
      in_record = payload_byte%32;
      if (record_no < 47) begin
        if (in_record < 4 && tdata !== ((record_no >> ((3-in_record)*8)) & 8'hff))
          $fatal(1,"record byte mismatch frame=%0d rec=%0d byte=%0d got=%02x",
                 frame_index,record_no,in_record,tdata);
        if (in_record >= 4 && tdata !== 0)
          $fatal(1,"record padding mismatch");
      end else if (tdata !== 0)
        $fatal(1,"final frame zero padding mismatch rec=%0d byte=%0d",record_no,in_record);
    end
    byte_index <= byte_index+1;
    if (tlast) begin
      frame_length[frame_index] <= byte_index+1;
      frame_index <= frame_index+1;
      byte_index <= 0;
    end
  end

  initial begin
    repeat(5) @(posedge clk); resetn=1;
    @(posedge clk); start=1; @(posedge clk); start=0;
    wait(done); @(posedge clk);
    if (beat_index != 24) $fatal(1,"expected 24 DDR beats got %0d",beat_index);
    if (frame_index != 3) $fatal(1,"expected 3 frames got %0d",frame_index);
    if (frame_length[0] != 1486 || frame_length[1] != 1486 ||
        frame_length[2] != 60)
      $fatal(1,"lengths %0d %0d %0d",frame_length[0],frame_length[1],frame_length[2]);
    $display("PASS tb_info_log_packetizer frames=%0d beats=%0d",frame_index,beat_index);
    $finish;
  end
  initial begin repeat(10000) @(posedge clk); $fatal(1,"timeout"); end
endmodule
