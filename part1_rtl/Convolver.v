// Convolver v15 - v14 + drop the cur_pass output mux in FEAT_ADD (WNS push, area down).
// v14 critical path = posedge feat_old -> 16b adder (feat_old+mac_result) -> cur_pass MUX2
//   -> feat_sum (posedge), full cycle, WNS -0.01. The MUX2 added the last ~0.06ns.
// v15: force feat_old=0 during pass0 (reset it; pass0 never enters FEAT_READ so it stays 0),
//   then ALWAYS compute feat_sum <= feat_old + mac_result. The mux disappears:
//   adder -> feat_sum directly => arrival ~1.18ns, WNS ~+0.04 (MET), and one 16b mux removed.
// Functionally identical (pass0: 0+mac_result=mac_result; pass1/2: feat_old+mac_result).
// Everything else identical to v14 (MAC-input pipeline reg + channel-serial + Feature RAM).
module Convolver
#(
    parameter ADDR_WIDTH  = 15,
    parameter IMAGE_WIDTH = 98,
    parameter FILTER_WIDTH = 5,
    parameter FEATURE_WIDTH = 32,
    parameter BITWIDTH    = 8
)(
    input wire clk,
    input wire resetn,
    input wire signed [BITWIDTH-1:0] IMAGE_RAM_DIN,
    input wire signed [BITWIDTH-1:0] FILTER_RAM_DIN,
    input wire signed [2*BITWIDTH-1:0] FEATURE_RAM_DIN,
    input wire IMAGE_RAM_DATA_VAL,
    input wire FILTER_RAM_DATA_VAL,
    input wire FEATURE_RAM_DATA_VAL,

    output wire IMAGE_RAM_EN,
    output wire FILTER_RAM_EN,
    output wire FEATURE_RAM_EN,
    output wire FEATURE_RAM_WEN,

    output wire [ADDR_WIDTH-1:0] IMAGE_RAM_ADDRESS,
    output wire [ADDR_WIDTH-1:0] FILTER_RAM_ADDRESS,
    output wire [ADDR_WIDTH-1:0] FEATURE_RAM_ADDRESS,

    output wire signed [2*BITWIDTH-1:0] FEATURE_RAM_DOUT,
    output wire eoc
);
    parameter IDLE             = 4'd0;
    parameter FILTER_LOAD      = 4'd1;
    parameter FILTER_LOAD_WAIT = 4'd2;
    parameter LINE_LOAD        = 4'd3;
    parameter LINE_LOAD_WAIT   = 4'd4;
    parameter PIXEL_INIT       = 4'd5;
    parameter MAC_PROC         = 4'd6;
    parameter COMPLETE_MAC     = 4'd7;
    parameter FEAT_READ        = 4'd8;
    parameter FEAT_READ_WAIT   = 4'd9;
    parameter FEAT_WRITE       = 4'd10;
    parameter ROW_NEXT         = 4'd11;
    parameter PASS_NEXT        = 4'd12;
    parameter EOC              = 4'd13;
    parameter FEAT_ADD         = 4'd14;   // register partial-sum add (off the output path)
    parameter COMPLETE_MAC2    = 4'd15;   // extra drain cycle for the MAC-input pipeline reg

    // RAM enables
    reg img_ram_en;
    reg fil_ram_en;
    reg fea_ram_en;
    reg fea_ram_wen;

    reg [3:0] cur_state, next_state;
    reg [ADDR_WIDTH-1:0] img_cur_addr, img_next_addr;
    reg [ADDR_WIDTH-1:0] fil_cur_addr, fil_next_addr;
    reg [ADDR_WIDTH-1:0] fea_cur_addr, fea_next_addr;   // = output pixel index (0..1023)

    reg [6:0] fil_load_cnt, next_fil_load_cnt;

    // Line load counters (single channel)
    reg [6:0] load_row, next_load_row;
    reg [6:0] load_col, next_load_col;
    reg [2:0] load_slot, next_load_slot;
    reg [6:0] load_row_start;
    reg [6:0] load_row_end;

    // MAC element counters (25 per channel-pixel)
    reg [5:0] cur_cnt, next_cnt;        // 0..25
    reg [2:0] cur_mac_dr, next_mac_dr;
    reg [2:0] cur_mac_dc, next_mac_dc;

    // Output pixel position
    reg [5:0] cur_col_cnt32, next_col_cnt32;
    reg [5:0] cur_row_cnt32, next_row_cnt32;
    reg [2:0] base_slot, next_base_slot;

    // Pass (channel) being processed: 0,1,2
    reg [1:0] cur_pass, next_pass;

    // Captured feature partial (pass1/2 read-modify-write; held at 0 through pass0 via reset).
    reg signed [2*BITWIDTH-1:0] feat_old;
    // Registered partial-sum result (drives FEATURE_RAM_DOUT; keeps the adder off the output path)
    reg signed [2*BITWIDTH-1:0] feat_sum;

    // MAC input pipeline registers (v14): break the half-cycle buffer-read path.
    reg signed [BITWIDTH-1:0] ifmap_p;
    reg signed [BITWIDTH-1:0] filter_p;

    // MAC controls
    wire mac_rstn;
    wire mac_en;
    wire [2*BITWIDTH-1:0] mac_result;

    // Filter buffer: filter_buf[i] = filter[i] (straight via load pipeline).
    reg signed [BITWIDTH-1:0] filter_buf [0:74];

    // Single-channel line buffer, banked by slot (5 banks x 99 col). 99*8=792 bit each (<4096).
    reg signed [BITWIDTH-1:0] lb0 [0:98];
    reg signed [BITWIDTH-1:0] lb1 [0:98];
    reg signed [BITWIDTH-1:0] lb2 [0:98];
    reg signed [BITWIDTH-1:0] lb3 [0:98];
    reg signed [BITWIDTH-1:0] lb4 [0:98];

    // ==========================================================
    // MAC element read index (STANDARD convolution, single channel = cur_pass)
    //   slot = (base_slot + cur_mac_dr) mod 5    // slot holds ifmap row 3R+dr
    //   col  = cur_col_cnt32*3 + cur_mac_dc + 1  // 1..98 ; buffer[col]=ifmap[col-1]
    // ==========================================================
    wire [3:0] slot_normal_tmp;
    wire [2:0] mac_target_slot;
    wire [6:0] mac_target_col;
    assign slot_normal_tmp = {1'b0, base_slot} + {1'b0, cur_mac_dr};
    assign mac_target_slot = (slot_normal_tmp >= 4'd5) ? (slot_normal_tmp[2:0] - 3'd5) : slot_normal_tmp[2:0];
    assign mac_target_col  = {1'b0, cur_col_cnt32} + {1'b0, cur_col_cnt32} + {1'b0, cur_col_cnt32} + {4'd0, cur_mac_dc} + 7'd1;

    // slot-banked read: select bank by slot, index by col (no multiply).
    wire signed [BITWIDTH-1:0] line_buf_rd;
    assign line_buf_rd = (mac_target_slot == 3'd0) ? lb0[mac_target_col] :
                         (mac_target_slot == 3'd1) ? lb1[mac_target_col] :
                         (mac_target_slot == 3'd2) ? lb2[mac_target_col] :
                         (mac_target_slot == 3'd3) ? lb3[mac_target_col] :
                                                     lb4[mac_target_col];

    // filter index: cur_pass*25 + element-offset(0..24). cnt=1..24->cnt-1, cnt>=25->24, cnt=0->0.
    wire [6:0] filter_off;
    wire [6:0] filter_buf_idx;
    assign filter_off = (cur_cnt == 6'd0) ? 7'd0 :
                        (cur_cnt >= 6'd25) ? 7'd24 :
                        ({1'b0, cur_cnt} - 7'd1);
    assign filter_buf_idx = ({5'd0, cur_pass} * 7'd25) + filter_off;

    wire signed [BITWIDTH-1:0] filter_data_for_mac;
    wire signed [BITWIDTH-1:0] ifmap_data_for_mac;
    assign filter_data_for_mac = filter_buf[filter_buf_idx];
    assign ifmap_data_for_mac  = line_buf_rd;

    // Load write: bank by load_slot, index by load_col.
    // (no separate wr index needed; case in the save block)

    // slot increment / reset (rolling), same as v11.
    wire [2:0] load_slot_inc;
    assign load_slot_inc = (load_slot == 3'd4) ? 3'd0 : (load_slot + 3'd1);
    wire [3:0] load_slot_reset_tmp;
    wire [2:0] load_slot_reset;
    assign load_slot_reset_tmp = {1'b0, base_slot} + 4'd2;
    assign load_slot_reset = (cur_row_cnt32 == 6'd0) ? 3'd0 :
                             (load_slot_reset_tmp >= 4'd5) ?
                                 (load_slot_reset_tmp[2:0] - 3'd5) :
                                 load_slot_reset_tmp[2:0];

    // Output connections
    assign IMAGE_RAM_EN   = img_ram_en;
    assign FILTER_RAM_EN  = fil_ram_en;
    assign FEATURE_RAM_EN = fea_ram_en;
    assign FEATURE_RAM_WEN = fea_ram_wen;
    assign IMAGE_RAM_ADDRESS  = img_cur_addr;
    assign FILTER_RAM_ADDRESS = fil_cur_addr;
    assign FEATURE_RAM_ADDRESS = fea_cur_addr;
    // write data: registered partial sum (computed in FEAT_ADD one cycle earlier).
    assign FEATURE_RAM_DOUT = feat_sum;
    assign eoc = (cur_state == EOC);

    assign mac_rstn = ~(cur_state == PIXEL_INIT);
    // v14: skip the fill cycle (MAC_PROC cnt==1) so the freshly-reset 0 buffers stay 0
    // until ifmap_p/filter_p hold element 0; COMPLETE_MAC2 flushes the last element.
    assign mac_en   = (cur_state == MAC_PROC && cur_cnt != 6'd1)
                   || (cur_state == COMPLETE_MAC)
                   || (cur_state == COMPLETE_MAC2);

    // ==========================================================
    // Sequential register update
    // ==========================================================
    always @ (posedge clk or negedge resetn) begin
        if(~resetn) begin
            cur_state     <= 0;
            img_cur_addr  <= 0;
            fil_cur_addr  <= 0;
            fea_cur_addr  <= 0;
            fil_load_cnt  <= 0;
            load_row      <= 0;
            load_col      <= 0;
            load_slot     <= 0;
            cur_cnt       <= 0;
            cur_mac_dr    <= 0;
            cur_mac_dc    <= 0;
            cur_col_cnt32 <= 0;
            cur_row_cnt32 <= 0;
            base_slot     <= 0;
            cur_pass      <= 0;
        end
        else begin
            cur_state     <= next_state;
            img_cur_addr  <= img_next_addr;
            fil_cur_addr  <= fil_next_addr;
            fea_cur_addr  <= fea_next_addr;
            fil_load_cnt  <= next_fil_load_cnt;
            load_row      <= next_load_row;
            load_col      <= next_load_col;
            load_slot     <= next_load_slot;
            cur_cnt       <= next_cnt;
            cur_mac_dr    <= next_mac_dr;
            cur_mac_dc    <= next_mac_dc;
            cur_col_cnt32 <= next_col_cnt32;
            cur_row_cnt32 <= next_row_cnt32;
            base_slot     <= next_base_slot;
            cur_pass      <= next_pass;
        end
    end

    // load_row_start/end from cur_row_cnt32 (R=0: 0..4 ; R>=1: 3R+2..3R+4)
    always @ (*) begin
        if (cur_row_cnt32 == 6'd0) begin
            load_row_start = 7'd0;
            load_row_end   = 7'd4;
        end
        else begin
            load_row_start = {1'b0, cur_row_cnt32} + {1'b0, cur_row_cnt32} + {1'b0, cur_row_cnt32} + 7'd2;
            load_row_end   = {1'b0, cur_row_cnt32} + {1'b0, cur_row_cnt32} + {1'b0, cur_row_cnt32} + 7'd4;
        end
    end

    // ==========================================================
    // Combinational FSM
    // ==========================================================
    always @ (*) begin
        next_state         = cur_state;
        img_next_addr      = img_cur_addr;
        fil_next_addr      = fil_cur_addr;
        fea_next_addr      = fea_cur_addr;
        next_fil_load_cnt  = fil_load_cnt;
        next_load_row      = load_row;
        next_load_col      = load_col;
        next_load_slot     = load_slot;
        next_cnt           = cur_cnt;
        next_mac_dr        = cur_mac_dr;
        next_mac_dc        = cur_mac_dc;
        next_col_cnt32     = cur_col_cnt32;
        next_row_cnt32     = cur_row_cnt32;
        next_base_slot     = base_slot;
        next_pass          = cur_pass;
        img_ram_en         = 1'b0;
        fil_ram_en         = 1'b0;
        fea_ram_en         = 1'b0;
        fea_ram_wen        = 1'b0;

        case(cur_state)
            IDLE: begin
                next_state    = FILTER_LOAD;
                img_next_addr = 0;
                fil_next_addr = 0;
                fea_next_addr = 0;
                next_fil_load_cnt = 0;
                next_load_row = 0; next_load_col = 0; next_load_slot = 0;
                next_cnt = 0; next_mac_dr = 0; next_mac_dc = 0;
                next_col_cnt32 = 0; next_row_cnt32 = 0; next_base_slot = 0;
                next_pass = 0;
            end

            // Load 75 filter weights (straight via pipeline). Used across all passes.
            FILTER_LOAD: begin
                next_state = FILTER_LOAD_WAIT;
                if (fil_load_cnt == 7'd74) fil_next_addr = 0;
                else fil_next_addr = {8'd0, fil_load_cnt} + 15'd1;
                fil_ram_en = 1'b1;
            end

            FILTER_LOAD_WAIT: begin
                if (FILTER_RAM_DATA_VAL == 1'b1) begin
                    if (fil_load_cnt == 7'd74) begin
                        next_state = LINE_LOAD;       // start pass 0
                        next_fil_load_cnt = 0;
                        next_load_row = 0; next_load_col = 0; next_load_slot = 0;
                    end
                    else begin
                        next_state = FILTER_LOAD;
                        next_fil_load_cnt = fil_load_cnt + 7'd1;
                    end
                end
                else next_state = FILTER_LOAD_WAIT;
            end

            // Load current channel (cur_pass) rows for output row R.
            LINE_LOAD: begin
                next_state = LINE_LOAD_WAIT;
                img_next_addr = {13'd0, cur_pass} * 15'd9604
                              + {8'd0, load_row} * 15'd98
                              + {8'd0, load_col};
                img_ram_en = 1'b1;
            end

            LINE_LOAD_WAIT: begin
                if (IMAGE_RAM_DATA_VAL == 1'b1) begin
                    if (load_col == 7'd98) begin     // load 0..98 (buffer[98]=ifmap col 97)
                        next_load_col = 0;
                        if (load_row == load_row_end) begin
                            next_load_row  = load_row_start;
                            next_load_slot = load_slot_reset;
                            next_state     = PIXEL_INIT;   // rows ready -> MAC
                            next_col_cnt32 = 0;
                        end
                        else begin
                            next_state    = LINE_LOAD;
                            next_load_row = load_row + 7'd1;
                            next_load_slot = load_slot_inc;
                        end
                    end
                    else begin
                        next_state    = LINE_LOAD;
                        next_load_col = load_col + 7'd1;
                    end
                end
                else next_state = LINE_LOAD_WAIT;
            end

            PIXEL_INIT: begin
                next_state  = MAC_PROC;
                next_cnt    = 6'd1;
                next_mac_dr = 0;
                next_mac_dc = 0;
            end

            // 25 MAC elements for this channel-pixel
            MAC_PROC: begin
                if (cur_cnt == 6'd25) begin
                    next_state = COMPLETE_MAC;
                    next_cnt = 0;
                end
                else begin
                    next_cnt = cur_cnt + 6'd1;
                    if (cur_mac_dc == 3'd4) begin
                        next_mac_dc = 0;
                        next_mac_dr = cur_mac_dr + 3'd1;   // dr 0..4 (cnt stops at 25)
                    end
                    else next_mac_dc = cur_mac_dc + 3'd1;
                end
            end

            // first drain cycle (accumulate element 23); COMPLETE_MAC2 flushes element 24
            COMPLETE_MAC: begin
                next_state = COMPLETE_MAC2;
            end

            // second drain cycle: flushes the 25th element through the MAC-input pipeline stage
            COMPLETE_MAC2: begin
                // pass0: feat_old held at 0 -> skip read, go straight to FEAT_ADD;
                // pass1/2: read the old partial first.
                if (cur_pass == 2'd0) next_state = FEAT_ADD;
                else                  next_state = FEAT_READ;
            end

            FEAT_READ: begin
                next_state  = FEAT_READ_WAIT;
                fea_ram_en  = 1'b1;
                fea_ram_wen = 1'b0;                 // read
            end

            FEAT_READ_WAIT: begin
                if (FEATURE_RAM_DATA_VAL == 1'b1) next_state = FEAT_ADD;
                else next_state = FEAT_READ_WAIT;
            end

            // register the partial sum (adder here is reg->reg, off the output path)
            FEAT_ADD: begin
                next_state = FEAT_WRITE;
            end

            FEAT_WRITE: begin
                fea_ram_en  = 1'b1;
                fea_ram_wen = 1'b1;                 // write FEATURE_RAM_DOUT
                fea_next_addr = fea_cur_addr + 15'd1;
                if (cur_col_cnt32 == 6'd31) begin
                    if (cur_row_cnt32 == 6'd31) next_state = PASS_NEXT; // last pixel of pass
                    else                         next_state = ROW_NEXT;
                end
                else begin
                    next_state = PIXEL_INIT;
                    next_col_cnt32 = cur_col_cnt32 + 6'd1;
                end
                next_cnt = 0;
            end

            // next output row within this pass (load 3 new rows)
            ROW_NEXT: begin
                next_state     = LINE_LOAD;
                next_row_cnt32 = cur_row_cnt32 + 6'd1;
                next_col_cnt32 = 0;
                if ({1'b0, base_slot} + 4'd3 >= 4'd5) next_base_slot = base_slot + 3'd3 - 3'd5;
                else                                  next_base_slot = base_slot + 3'd3;
                next_load_row  = {1'b0, cur_row_cnt32} + {1'b0, cur_row_cnt32} + {1'b0, cur_row_cnt32} + 7'd5;
                next_load_col  = 0;
                next_load_slot = base_slot;
            end

            // next pass (channel), or finish after pass 2
            PASS_NEXT: begin
                if (cur_pass == 2'd2) next_state = EOC;
                else begin
                    next_state    = LINE_LOAD;
                    next_pass     = cur_pass + 2'd1;
                    next_row_cnt32 = 0;
                    next_col_cnt32 = 0;
                    next_base_slot = 0;
                    next_load_row  = 0;
                    next_load_col  = 0;
                    next_load_slot = 0;
                    fea_next_addr  = 0;            // restart partial-sum address for new pass
                end
            end

            EOC: next_state = EOC;

            default: next_state = IDLE;
        endcase
    end

    // ==========================================================
    // Filter buffer save
    // ==========================================================
    always @ (posedge clk) begin
        if (cur_state == FILTER_LOAD_WAIT && FILTER_RAM_DATA_VAL) begin
            filter_buf[fil_load_cnt] <= FILTER_RAM_DIN;
        end
    end

    // ==========================================================
    // Line buffer save (slot-banked)
    // ==========================================================
    always @ (posedge clk) begin
        if (cur_state == LINE_LOAD_WAIT && IMAGE_RAM_DATA_VAL) begin
            case (load_slot)
                3'd0: lb0[load_col] <= IMAGE_RAM_DIN;
                3'd1: lb1[load_col] <= IMAGE_RAM_DIN;
                3'd2: lb2[load_col] <= IMAGE_RAM_DIN;
                3'd3: lb3[load_col] <= IMAGE_RAM_DIN;
                default: lb4[load_col] <= IMAGE_RAM_DIN;
            endcase
        end
    end

    // ==========================================================
    // MAC input pipeline register (v14): register the slot-banked read and the
    // filter read on posedge so the big mux gets a full cycle. MAC then captures
    // a stable flop on negedge (flop->flop, no mux), removing the half-cycle path.
    // ==========================================================
    always @ (posedge clk) begin
        ifmap_p  <= ifmap_data_for_mac;
        filter_p <= filter_data_for_mac;
    end

    // ==========================================================
    // Feature partial capture (pass 1,2 read-modify-write).
    // v15: reset to 0 so pass0 (which never enters FEAT_READ) keeps feat_old==0,
    // letting FEAT_ADD use a bare adder (no cur_pass mux) -> shorter critical path.
    // ==========================================================
    always @ (posedge clk or negedge resetn) begin
        if (~resetn) feat_old <= 0;
        else if (cur_state == FEAT_READ_WAIT && FEATURE_RAM_DATA_VAL) feat_old <= FEATURE_RAM_DIN;
    end

    // ==========================================================
    // Partial-sum add, registered in FEAT_ADD. v15: always feat_old+mac_result
    // (pass0: feat_old==0 -> = mac_result). No cur_pass output mux on this path.
    // ==========================================================
    always @ (posedge clk) begin
        if (cur_state == FEAT_ADD) begin
            feat_sum <= feat_old + mac_result;
        end
    end

    // ==========================================================
    // MAC instance (fed by the v14 pipeline registers)
    // ==========================================================
    MAC mac0 (
        .CLK (~clk),
        .RSTN(mac_rstn),
        .EN(mac_en),
        .IFMAP_DATA_IN(ifmap_p),
        .FILTER_DATA_IN(filter_p),
        .MUL_DATA_OUT(mac_result)
    );

endmodule
