// Minimal Qt Widgets application used to prove that a freshly built
// "Qt 6 for Windows 7" prefix can actually compile and link an app.
#include <QApplication>
#include <QLabel>
#include <QString>
#include <QVBoxLayout>
#include <QWidget>
#include <QSslSocket>

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    QString info = QStringLiteral("Qt %1 (built for Windows 7)\nSSL: %2")
                       .arg(QString::fromLatin1(qVersion()),
                            QSslSocket::supportsSsl() ? QStringLiteral("yes")
                                                      : QStringLiteral("no"));

    QWidget window;
    window.setWindowTitle(QStringLiteral("Qt 6 Windows 7 smoke test"));
    auto *layout = new QVBoxLayout(&window);
    auto *label = new QLabel(info);
    label->setAlignment(Qt::AlignCenter);
    layout->addWidget(label);
    window.resize(360, 140);

    return 0;
}
