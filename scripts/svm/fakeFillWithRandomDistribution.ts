// Retained as an explicit migration notice for existing devnet callers.
// Destination actions now belong in the V5 Gateway tape; see test/svm-gateway/README.md.
throw new Error(
  "Legacy fill callbacks have been retired. Use a V5 Gateway fill followed by committed destination commands."
);
export {};
