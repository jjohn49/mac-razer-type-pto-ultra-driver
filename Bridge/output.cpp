// Uses the Boost-licensed pqrs virtual-HID client; see THIRD_PARTY.md.
#include <atomic>
#include <iostream>
#include <sstream>
#include <thread>
#include <unistd.h>
#include <pqrs/karabiner/driverkit/virtual_hid_device_driver.hpp>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>

namespace report = pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report;
using Client = pqrs::karabiner::driverkit::virtual_hid_device_service::client;

int main() {
  if (geteuid() != 0) { std::cerr << "Run via the installed input helper.\n"; return 1; }
  pqrs::dispatcher::extra::initialize_shared_dispatcher();
  auto client = std::make_unique<Client>();
  std::atomic<bool> keyboard{false}, pointing{false}, ready{false};
  auto update = [&] {
    bool next = keyboard && pointing;
    if (ready.exchange(next) != next) std::cout << (next ? "READY" : "LOST") << std::endl;
  };
  client->connected.connect([&] {
    pqrs::karabiner::driverkit::virtual_hid_device_service::virtual_hid_keyboard_parameters p;
    p.set_country_code(pqrs::hid::country_code::us);
    client->async_virtual_hid_keyboard_initialize(p);
    client->async_virtual_hid_pointing_initialize();
  });
  client->virtual_hid_keyboard_ready.connect([&](bool value) { keyboard=value; update(); });
  client->virtual_hid_pointing_ready.connect([&](bool value) { pointing=value; update(); });
  client->closed.connect([&] { keyboard=false; pointing=false; update(); });
  client->error_occurred.connect([&](auto&&) { keyboard=false; pointing=false; update(); });
  client->driver_version_mismatched.connect([&](bool mismatch) {
    if (mismatch) { keyboard=false; pointing=false; update(); std::cout << "ERROR Version mismatch" << std::endl; }
  });
  client->async_start();
  report::keyboard_input keys;
  report::consumer_input consumer;
  report::generic_desktop_input desktop;
  report::pointing_input mouse;
  auto reset = [&] {
    keys = {}; consumer = {}; desktop = {}; mouse = {};
    client->async_post_report(keys); client->async_post_report(consumer);
    client->async_post_report(desktop); client->async_post_report(mouse);
  };
  for (std::string line; std::getline(std::cin,line);) {
    if (line.size() > 100) break;
    std::istringstream input(line);
    char command; input >> command;
    if (command == 'R') { reset(); continue; }
    if (!ready) continue;
    if (command == 'K') {
      unsigned page,usage,down;
      if (!(input >> page >> usage >> down) || down > 1) break;
      if (page == 7 && usage >= 4 && usage <= 231) {
        if (usage >= 224) {
          auto modifier = static_cast<report::modifier>(1u << (usage-224));
          if (down) keys.modifiers.insert(modifier); else keys.modifiers.erase(modifier);
        } else { if (down) keys.keys.insert(usage); else keys.keys.erase(usage); }
        client->async_post_report(keys);
      } else if (page == 12 && usage <= 0x3ff) {
        if (down) consumer.keys.insert(usage); else consumer.keys.erase(usage);
        client->async_post_report(consumer);
      } else if (page == 1 && usage >= 0x81 && usage <= 0x83) {
        if (down) desktop.keys.insert(usage); else desktop.keys.erase(usage);
        client->async_post_report(desktop);
      } else if (page == 9 && usage >= 1 && usage <= 32) {
        if (down) mouse.buttons.insert(usage); else mouse.buttons.erase(usage);
        client->async_post_report(mouse);
      }
    } else if (command == 'P') {
      int x,y,wheel;
      if (!(input >> x >> y >> wheel) || x < -127 || x > 127 || y < -127 || y > 127 || wheel < -127 || wheel > 127) break;
      mouse.x=static_cast<uint8_t>(x); mouse.y=static_cast<uint8_t>(y); mouse.vertical_wheel=static_cast<uint8_t>(wheel);
      client->async_post_report(mouse);
      mouse.x=0; mouse.y=0; mouse.vertical_wheel=0;
    } else break;
  }
  reset();
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  client.reset();
  pqrs::dispatcher::extra::terminate_shared_dispatcher();
}
