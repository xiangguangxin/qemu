// Personal local experiment only; not for QEMU upstream contribution.
#include <systemc>
#include <tlm>
#include <tlm_utils/simple_initiator_socket.h>
#include <tlm_utils/simple_target_socket.h>
#include <cstdint>
#include <iostream>
using namespace sc_core;

SC_MODULE(Register) {
    tlm_utils::simple_target_socket<Register> socket{"socket"};
    uint32_t value = 0;
    void transport(tlm::tlm_generic_payload &tx, sc_time &delay) {
        tx.set_dmi_allowed(false);
        if (tx.get_address() != 0) {
            tx.set_response_status(tlm::TLM_ADDRESS_ERROR_RESPONSE);
            return;
        }
        if (tx.get_data_length() != 4 || tx.get_streaming_width() != 4 ||
            tx.get_data_ptr() == nullptr) {
            tx.set_response_status(tlm::TLM_BURST_ERROR_RESPONSE);
            return;
        }
        if (tx.get_byte_enable_ptr() != nullptr) {
            tx.set_response_status(tlm::TLM_BYTE_ENABLE_ERROR_RESPONSE);
            return;
        }
        if (!tx.is_read() && !tx.is_write()) {
            tx.set_response_status(tlm::TLM_COMMAND_ERROR_RESPONSE);
            return;
        }
        // This model consumes incoming annotation and local delay exactly once.
        wait(delay + sc_time(10, SC_NS));
        delay = SC_ZERO_TIME;
        auto *p = tx.get_data_ptr();
        if (tx.is_write()) {
            value = uint32_t(p[0]) | uint32_t(p[1]) << 8 |
                    uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
        } else {
            for (unsigned i = 0; i < 4; ++i) p[i] = value >> (i * 8);
        }
        tx.set_response_status(tlm::TLM_OK_RESPONSE);
    }
    SC_CTOR(Register) { socket.register_b_transport(this, &Register::transport); }
};
SC_MODULE(Bench) {
    tlm_utils::simple_initiator_socket<Bench> socket{"socket"};
    bool passed = false;
    void run() {
        unsigned char bytes[4] = {0x78, 0x56, 0x34, 0x12};
        tlm::tlm_generic_payload tx;
        tx.set_address(0);
        tx.set_data_ptr(bytes);
        tx.set_data_length(4);
        tx.set_streaming_width(4);
        tx.set_byte_enable_ptr(nullptr);
        tx.set_command(tlm::TLM_WRITE_COMMAND);
        tx.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
        sc_time delay(5, SC_NS);
        socket->b_transport(tx, delay);
        sc_assert(tx.is_response_ok() && delay == SC_ZERO_TIME);
        sc_assert(sc_time_stamp() == sc_time(15, SC_NS));
        for (auto &b : bytes) b = 0;
        tx.set_command(tlm::TLM_READ_COMMAND);
        tx.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
        socket->b_transport(tx, delay);
        sc_assert(tx.is_response_ok() && bytes[0] == 0x78 && bytes[1] == 0x56 &&
                  bytes[2] == 0x34 && bytes[3] == 0x12);
        sc_assert(sc_time_stamp() == sc_time(25, SC_NS));
        tx.set_address(4);
        tx.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
        socket->b_transport(tx, delay);
        sc_assert(tx.get_response_status() == tlm::TLM_ADDRESS_ERROR_RESPONSE);
        tx.set_address(0);
        tx.set_data_length(1);
        socket->b_transport(tx, delay);
        sc_assert(tx.get_response_status() == tlm::TLM_BURST_ERROR_RESPONSE);
        tx.set_data_length(4);
        unsigned char enable[4] = {255, 255, 255, 255};
        tx.set_byte_enable_ptr(enable);
        socket->b_transport(tx, delay);
        sc_assert(tx.get_response_status() == tlm::TLM_BYTE_ENABLE_ERROR_RESPONSE);
        tx.set_byte_enable_ptr(nullptr);
        tx.set_command(tlm::TLM_IGNORE_COMMAND);
        socket->b_transport(tx, delay);
        sc_assert(tx.get_response_status() == tlm::TLM_COMMAND_ERROR_RESPONSE);
        sc_assert(sc_time_stamp() == sc_time(25, SC_NS));
        passed = true;
        std::cout << "PASS register: data, errors, time=" << sc_time_stamp() << '\n';
        sc_stop();
    }
    SC_CTOR(Bench) { SC_THREAD(run); }
};
int sc_main(int, char **) {
    sc_set_time_resolution(1, SC_PS);
    Register device("device");
    Bench bench("bench");
    bench.socket.bind(device.socket);
    sc_start();
    return bench.passed ? 0 : 1;
}
