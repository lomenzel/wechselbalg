# Strongly Connected Components (Tarjan's algorithm) in pure Nix.
#
# Input:
#   graph: attrset where keys are node names, and values are lists of target node names.
#   e.g.:
#     {
#       a = [ "b" ];
#       b = [ "c" "a" ]; # a and b mutually recursive
#       c = [ ];         # leaf
#     }
#
# Output:
#   List of SCCs in bottom-up topological order (dependencies/leaves first):
#     [ [ "c" ] [ "b" "a" ] ]

let
  reverseList =
    list:
    let
      len = builtins.length list;
    in
    builtins.genList (i: builtins.elemAt list (len - 1 - i)) len;

  # Find all SCCs in a directed graph.
  # graph: { nodeName = [ depName ... ]; }
  scc =
    graph:
    let
      allNodes = builtins.attrNames graph;

      # State threaded through DFS:
      # {
      #   index: int,
      #   nodes: { ${node} = { i: int, low: int, on: bool }; },
      #   stack: [ string ],
      #   sccs: [ [ string ] ]
      # }
      initialState = {
        index = 0;
        nodes = { };
        stack = [ ];
        sccs = [ ];
      };

      # DFS visit for a single node
      strongConnect =
        state: u:
        let
          uIndex = state.index;
          state1 = state // {
            index = uIndex + 1;
            nodes = state.nodes // {
              ${u} = {
                i = uIndex;
                low = uIndex;
                on = true;
              };
            };
            stack = [ u ] ++ state.stack;
          };

          neighbors = builtins.filter (v: graph ? ${v}) (graph.${u} or [ ]);

          stateAfterNeighbors = builtins.foldl' (
            st: v:
            let
              vNode = st.nodes.${v} or null;
              uNode = st.nodes.${u};
            in
            if vNode == null then
              # Successor v has not yet been visited; recurse on it
              let
                stVisited = strongConnect st v;
                visitedVNode = stVisited.nodes.${v};
                visitedUNode = stVisited.nodes.${u};
                newLow = if visitedVNode.low < visitedUNode.low then visitedVNode.low else visitedUNode.low;
              in
              stVisited
              // {
                nodes = stVisited.nodes // {
                  ${u} = visitedUNode // {
                    low = newLow;
                  };
                };
              }
            else if vNode.on then
              # Successor v is on stack and hence in the current SCC
              let
                newLow = if vNode.i < uNode.low then vNode.i else uNode.low;
              in
              st
              // {
                nodes = st.nodes // {
                  ${u} = uNode // {
                    low = newLow;
                  };
                };
              }
            else
              st
          ) state1 neighbors;

          stFinal = stateAfterNeighbors;
          curUNode = stFinal.nodes.${u};
        in
        if curUNode.low == curUNode.i then
          let
            # Pop elements from stack until u is popped (using O(1) prepend)
            popResult = popUntil u stFinal.stack [ ];
            sccGroup = popResult.popped;
            remainingStack = popResult.rest;

            # Mark popped elements as no longer on stack in a single listToAttrs
            offStackAttrs = builtins.listToAttrs (
              builtins.map (name: {
                inherit name;
                value = (stFinal.nodes.${name}) // {
                  on = false;
                };
              }) sccGroup
            );
          in
          stFinal
          // {
            stack = remainingStack;
            nodes = stFinal.nodes // offStackAttrs;
            # Prepend completed SCC to accumulator (leaves completed first)
            sccs = [ sccGroup ] ++ stFinal.sccs;
          }
        else
          stFinal;

      # Helper to pop until target node is reached (O(1) prepends, reverse at end)
      popUntil =
        target: stack: poppedRev:
        if stack == [ ] then
          {
            popped = reverseList poppedRev;
            rest = [ ];
          }
        else
          let
            top = builtins.head stack;
            rest = builtins.tail stack;
          in
          if top == target then
            {
              popped = reverseList ([ top ] ++ poppedRev);
              inherit rest;
            }
          else
            popUntil target rest ([ top ] ++ poppedRev);

      # Run DFS across all unvisited nodes
      finalState = builtins.foldl' (
        st: node: if st.nodes ? ${node} then st else strongConnect st node
      ) initialState allNodes;

    in
    reverseList finalState.sccs;
in
{
  inherit scc;
}
