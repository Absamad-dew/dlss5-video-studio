"""Shape-bounded, numerically checked CUDA graph executor for Studio VR only."""
import torch


class ValidatedCudaGraph:
    def __init__(self, model):
        self.model = model
        self.state = None
        self.disabled_reason = None
        self.validated_replays = 0

    def _forward(self, x):
        # Cached autocast weight copies can outlive their owning context during
        # graph replay. Capture their allocation in the graph's private pool.
        with torch.autocast('cuda',dtype=torch.get_autocast_dtype('cuda'),
                            enabled=torch.is_autocast_enabled('cuda'),cache_enabled=False):
            output = self.model(x)
        # DA3's aux is an empty dictionary when feature export is off.
        # The depth consumer reads only tensors, including depth and sky.
        if isinstance(output, dict) and 'depth' in output:
            return {k: v for k,v in output.items() if torch.is_tensor(v)}
        return output

    def __call__(self, x):
        if self.disabled_reason:
            return self._forward(x)
        if self.state is not None:
            shape, buffer, graph, output = self.state
            if tuple(x.shape) != shape:
                # Bounded to one graph. Shape changes never create an unbounded cache.
                return self._forward(x)
            buffer.copy_(x)
            graph.replay()
            result = {k: v.clone() for k, v in output.items()}
            finite = all(bool(torch.isfinite(v).all()) for v in result.values())
            if self.validated_replays < 3 or not finite:
                expected = self._forward(x)
                if not finite or not all(torch.equal(result[k],expected[k]) for k in result):
                    self.disabled_reason = 'replay differs from eager; retaining eager output'
                    self.state = None
                    print('VR_DEPTH_GRAPH_FALLBACK '+self.disabled_reason,flush=True)
                    return expected
                self.validated_replays += 1
            return result
        reference = self._forward(x)
        if not isinstance(reference, dict) or not all(torch.is_tensor(v) for v in reference.values()):
            self.disabled_reason = 'non-tensor model output'
            print('VR_DEPTH_GRAPH_FALLBACK '+self.disabled_reason,flush=True)
            return reference
        try:
            static = x.clone()
            stream = torch.cuda.Stream()
            stream.wait_stream(torch.cuda.current_stream())
            with torch.cuda.stream(stream):
                for _ in range(2):
                    self._forward(static)
            torch.cuda.current_stream().wait_stream(stream)
            graph = torch.cuda.CUDAGraph()
            with torch.cuda.graph(graph):
                output = self._forward(static)
            graph.replay()
            if not all(torch.equal(reference[k], output[k]) for k in reference):
                raise ValueError('graph output differs from eager on capture frame')
            self.state = tuple(x.shape), static, graph, output
            print('VR_DEPTH_GRAPH_READY', flush=True)
        except (RuntimeError, ValueError) as error:
            self.disabled_reason = str(error)
            print('VR_DEPTH_GRAPH_FALLBACK ' + self.disabled_reason, flush=True)
        return reference
