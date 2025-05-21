// Import the fuzzer base class
import { Fuzzer } from "../../harness/fuzzer.js";

// The custom fuzzer needs to subclass the Fuzzer class to work properly
class TestFuzzer extends Fuzzer {
    constructor() {
        // The constructor needs to specify the address of the targeted function and a NativeFunction
        // object that can later be called by the fuzzer.

        const fn_addr = Module.getGlobalExportByName("protocol_handler");
        const protocol_handler = new NativeFunction(
            fn_addr,
            "void", ["int", "int", "pointer"]);

        // The constructor needs:
        //      - the module name
        //      - the address of the targeted function
        //      - the NativeFunction object of the targeted function
        super("protocol_example", fn_addr, protocol_handler);
    }

    // The pepare function is called once the script is loaded into the target process in case any
    // preparation or state setup is required. In this case, no preparation is needed (see the bluetoothd
    // example for a preparation function that does something)
    prepare() {
        const fn_addr = Module.getGlobalExportByName("create_connection");
        const create_connection = new NativeFunction(fn_addr, "int", ["int"]);

        // replace the disconnect function to prevent connection from being disconnected
        Interceptor.replace(Module.getGlobalExportByName("disconnect"),
            new NativeCallback((handle) => {
                return;
            }, 'void', ['int'])
        );

        // create connection with 934 as fd, which should not be taken
        this.handle = create_connection(934);
    }

    // This function is called by the fuzzer with the first argument being a pointer into memory
    // where the payload is stored and the second the length of the input.
    fuzz(payload, len) {
        const buf = Memory.alloc(len + 1); // Allocate space for 'U' + payload
        // copy to a new buffer and prepend "U" so that the process
        // accepts the message

        buf.writeUtf8String('U');
        if (len > 0) {
            buf.add(1).writeByteArray(payload.readByteArray(len));
        }

        this.target_function(this.handle, parseInt(len) + 1, buf); // Length is now len + 1 because of 'U'
    }

}

const f = new TestFuzzer();
rpc.exports.fuzzer = f;
