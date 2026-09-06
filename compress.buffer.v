// -----------------------------------------------------------------------------
// compress.buffer.v — Verilog port of compress.buffer.vi
//
// Realigns the parser buffer after consuming 'consume' bytes from the front
// (the 8-byte Sequenced Unit Header or one whole message). Because buffer
// byte 0 lives at the MSB, dropping the front bytes is a left shift.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module compress_buffer (
    input  wire [575:0] buffer_in,
    input  wire [6:0]   buffer_length_in,
    input  wire [6:0]   consume,           // bytes to drop from the front
    output wire [575:0] buffer_out,
    output wire [6:0]   buffer_length_out
);

    assign buffer_out        = buffer_in << (8 * consume);
    assign buffer_length_out = buffer_length_in - consume;

endmodule

`default_nettype wire
