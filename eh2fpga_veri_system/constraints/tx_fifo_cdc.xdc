# TX FIFO clock-crossing constraints copied from the TEMAC example design.
# Only the instance name is adapted from tx_fifo_i to tx_client_fifo_i.
# These paths carry Gray/toggle values with separately synchronized controls
# and therefore use the example design's 3.2 ns datapath-only requirement.

set_max_delay -from [get_cells -hier -filter {name =~ *tx_client_fifo_i/rd_addr_txfer_reg[*]}] \
  -to [get_cells -hier -filter {name =~ *fifo*wr_rd_addr_reg[*]}] 3.2 -datapath_only
set_max_delay -from [get_cells -hier -filter {name =~ *tx_client_fifo_i/wr_frame_in_fifo_reg}] \
  -to [get_cells -hier -filter {name =~ *tx_client_fifo_i/resync_wr_frame_in_fifo/data_sync_reg0}] 3.2 -datapath_only
set_max_delay -from [get_cells -hier -filter {name =~ *tx_client_fifo_i/wr_frames_in_fifo_reg}] \
  -to [get_cells -hier -filter {name =~ *tx_client_fifo_i/resync_wr_frames_in_fifo/data_sync_reg0}] 3.2 -datapath_only
set_max_delay -from [get_cells -hier -filter {name =~ *tx_client_fifo_i/frame_in_fifo_valid_tog_reg}] \
  -to [get_cells -hier -filter {name =~ *tx_client_fifo_i/resync_fif_valid_tog/data_sync_reg0}] 3.2 -datapath_only
set_max_delay -from [get_cells -hier -filter {name =~ *tx_client_fifo_i/rd_txfer_tog_reg}] \
  -to [get_cells -hier -filter {name =~ *tx_client_fifo_i/resync_rd_txfer_tog/data_sync_reg0}] 3.2 -datapath_only
set_max_delay -from [get_cells -hier -filter {name =~ *tx_client_fifo_i/rd_tran_frame_tog_reg}] \
  -to [get_cells -hier -filter {name =~ *tx_client_fifo_i/resync_rd_tran_frame_tog/data_sync_reg0}] 3.2 -datapath_only

