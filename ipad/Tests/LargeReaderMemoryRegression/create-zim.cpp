#include <zim/writer/creator.h>
#include <zim/writer/item.h>
#include <memory>
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    zim::writer::Creator creator;
    creator.configCompression(zim::Compression::None).configIndexing(false, "en");
    creator.startZimCreation(argv[2]);
    creator.addItem(std::make_shared<zim::writer::FileItem>("test.bin", "application/octet-stream", "Synthetic memory fixture", zim::writer::Hints{{zim::writer::COMPRESS, 0}}, argv[1]));
    creator.finishZimCreation();
}
