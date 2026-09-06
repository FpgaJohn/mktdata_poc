// bats.parser.vh — shared codes for the bats.parser Verilog port.
// Included INSIDE module bodies (localparams), so no include guard.

// PITCH message types handled by the parser
localparam [7:0] MSG_TIME              = 8'h20,
                 MSG_ADD_ORDER_LONG    = 8'h21,
                 MSG_ADD_ORDER_SHORT   = 8'h22,
                 MSG_ORDER_EXECUTED    = 8'h23,
                 MSG_ORDER_EXECUTED_PS = 8'h24,
                 MSG_ADD_ORDER_EXP     = 8'h2F;

// OrderBook.Command.type encoding (the VI uses a LabVIEW enum; the exact
// numeric values were not recoverable from the printouts).
localparam [7:0] TYPE_ADD_ORDER      = 8'd1,
                 TYPE_ORDER_EXECUTED = 8'd2;
