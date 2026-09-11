// protoc for the host, with only the C++ backend registered. Upstream's own
// main.cc names every language generator, and the pin carries none of them:
// the sole caller is the CoreML model spec, which this build compiles to C++
// rather than vendoring anyone's generated output.
#include "google/protobuf/compiler/command_line_interface.h"
#include "google/protobuf/compiler/cpp/generator.h"

int main(int argc, char *argv[]) {
    google::protobuf::compiler::CommandLineInterface cli;
    google::protobuf::compiler::cpp::CppGenerator cpp;
    cli.RegisterGenerator("--cpp_out", "--cpp_opt", &cpp, "Generate C++ source and header.");
    return cli.Run(argc, argv);
}
