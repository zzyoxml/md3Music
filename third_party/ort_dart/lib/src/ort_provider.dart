/// An enumerated value of ort provider.
enum OrtProvider {
  cpu('CPUExecutionProvider'),
  coreml('CoreMLExecutionProvider'),
  nnapi('NnapiExecutionProvider'),
  qnn('QNNExecutionProvider'),
  xnnpack('XnnpackExecutionProvider');

  final String value;

  const OrtProvider(this.value);

  static OrtProvider valueOf(String value) {
    if (value == cpu.value) {
      return cpu;
    }
    if (value == coreml.value) {
      return coreml;
    }
    if (value == nnapi.value) {
      return nnapi;
    }
    if (value == xnnpack.value) {
      return xnnpack;
    }
    if (value == qnn.value) {
      return qnn;
    }
    return OrtProvider.cpu;
  }
}
