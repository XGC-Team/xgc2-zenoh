// Real C++ peer for the Python SDK interop gate. Its endpoint is an isolated
// UDP router supplied by the test, not a station or robot.
#include <atomic>
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

#include "zenoh.hxx"

namespace {
using Clock = std::chrono::steady_clock;

template <class Predicate>
void await(const char* what, Predicate condition) {
  const auto deadline = Clock::now() + std::chrono::seconds(12);
  while (!condition()) {
    if (Clock::now() >= deadline) throw std::runtime_error(std::string("timeout waiting for ") + what);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
}
}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) return 2;
  try {
    zenoh::try_init_log_from_env();
    const std::string endpoint = argv[1];
    const std::string root = argv[2];
    const std::string from_python = root + "/py-to-cpp";
    const std::string to_python = root + "/cpp-to-py";
    const std::string query_cpp = root + "/query-cpp";
    const std::string query_python = root + "/query-python";
    auto config = zenoh::Config::from_str(
        "{mode:\"client\",connect:{endpoints:[\"" + endpoint +
        "\"],timeout_ms:5000,exit_on_failure:true},"
        "scouting:{multicast:{enabled:false},gossip:{enabled:false}}}");
    auto session = zenoh::Session::open(std::move(config));

    std::atomic<bool> stream_link{false}, datagram_link{false};
    zenoh::Session::LinkEventsListenerOptions links;
    links.history = true;
    auto listener = session.declare_link_events_listener(
        [&](zenoh::LinkEvent& event) {
          if (event.get_kind() != Z_SAMPLE_KIND_PUT) return;
          const auto& link = event.get_link();
          const auto reliability = link.get_reliability();
          if (reliability && *reliability == Z_RELIABILITY_RELIABLE && link.is_streamed()) stream_link = true;
          if (reliability && *reliability == Z_RELIABILITY_BEST_EFFORT && !link.is_streamed()) datagram_link = true;
        }, zenoh::closures::none, std::move(links));

    std::atomic<bool> received_python{false}, handled_python_query{false}, received_cpp_reply{false}, bad{false};
    auto subscriber = session.declare_subscriber(
        zenoh::KeyExpr(from_python), [&](zenoh::Sample& sample) {
          if (sample.get_payload().as_string() == "python-pub") received_python = true;
          else bad = true;
        }, zenoh::closures::none);
    auto queryable = session.declare_queryable(
        zenoh::KeyExpr(query_cpp), [&](zenoh::Query& query) {
          try {
            auto payload = query.get_payload();
            if (!payload || payload->get().as_string() != "python-request") {
              bad = true;
              return;
            }
            query.reply(zenoh::KeyExpr(query_cpp), zenoh::Bytes("cpp-reply"));
            handled_python_query = true;
          } catch (...) { bad = true; }
        }, zenoh::closures::none);

    zenoh::Session::PublisherOptions publisher_options;
    publisher_options.reliability = Z_RELIABILITY_BEST_EFFORT;
    publisher_options.congestion_control = Z_CONGESTION_CONTROL_DROP;
    publisher_options.priority = Z_PRIORITY_REAL_TIME;
    publisher_options.is_express = true;
    auto publisher = session.declare_publisher(zenoh::KeyExpr(to_python), std::move(publisher_options));
    zenoh::Session::QuerierOptions querier_options;
    querier_options.timeout_ms = 5000;
    auto querier = session.declare_querier(zenoh::KeyExpr(query_python), std::move(querier_options));

    await("mixed links and Python subscribers/queryable", [&] {
      return stream_link && datagram_link && publisher.get_matching_status().matching &&
             querier.get_matching_status().matching;
    });
    // BEST_EFFORT permits an individual sample to be dropped; exercise a short
    // stream rather than requiring a one-shot delivery from the transport.
    for (int i = 0; i < 10; ++i) {
      publisher.put(zenoh::Bytes("cpp-pub"));
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    zenoh::Querier::GetOptions query_options;
    query_options.payload.emplace("cpp-request");
    querier.get("", [&](zenoh::Reply& reply) {
      if (reply.is_ok() && reply.get_ok().get_payload().as_string() == "python-reply") received_cpp_reply = true;
      else bad = true;
    }, zenoh::closures::none, std::move(query_options));

    await("Python pub/sub and both query/reply directions", [&] {
      if (bad) throw std::runtime_error("C++ received an unexpected payload or error reply");
      return received_python && handled_python_query && received_cpp_reply;
    });
    std::cout << "cpp: mixed links, Python->C++ pub, C++->Python pub, both query/reply payloads OK" << std::endl;
    std::string done;
    if (!std::getline(std::cin, done) || done != "finish") throw std::runtime_error("Python did not finish");
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "C++ interop failure: " << e.what() << std::endl;
    return 1;
  }
}
