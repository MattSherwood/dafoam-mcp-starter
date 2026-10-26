# Glossary — one line each

Enough to answer a question without wobbling. If you don't know, say
"let me check and come back to you" — that is the correct professional answer and
models the behaviour the workshop teaches.

## The flow

| Term | One line |
|---|---|
| **NACA 2412** | A classic airfoil: 2% mean camber, at 40% chord, 12% thick. A 4-digit naming convention from NACA. |
| **Camber** | The asymmetry between the upper and lower surface curves. Camber is why a symmetric airfoil at 0° makes no lift but a cambered one does. |
| **Angle of attack (AoA)** | The nose-up angle between the airfoil's chord line and the oncoming flow, in degrees. |
| **Mach number** | Speed relative to the speed of sound. 0.15 ≈ 51 m/s at sea level; below ~0.3 air behaves as incompressible. |
| **Reynolds number** | Inertia ÷ viscosity. Sets whether the boundary layer is laminar or turbulent. 1×10⁶ is small-aircraft/glider scale. |
| **Zero-lift angle** | The AoA at which lift is zero. About −2° for NACA 2412 because of camber. |
| **Lift curve slope** | How fast lift grows with AoA. A 2D section: ≈0.11 per degree (2π per radian). This is your mental arithmetic tool. |
| **Stall** | Flow separation at high AoA; lift collapses. Steady RANS does not predict it reliably. |

## The coefficients

| Term | One line |
|---|---|
| **C_L** (lift coefficient) | Lift normalised by dynamic pressure × chord. Dimensionless. |
| **C_D** (drag coefficient) | Drag normalised the same way. Typical airfoil values are ~0.008–0.015. |
| **C_M** (pitching moment) | The rotating moment on the section, usually about the quarter-chord. Negative = nose-down. |
| **L/D** | Lift-to-drag ratio. The single best "efficiency" number for a wing section. |
| **Dynamic pressure** | ½ρV². The "pressure" of moving air; coefficients factor it out so results are comparable. |

## The numerics

| Term | One line |
|---|---|
| **Mesh** | The grid of small volumes the equations are solved on. More cells = more detail = slower. |
| **y⁺ (y-plus)** | Distance of the first grid cell from the wall, in viscous units. y⁺≈1 resolves the boundary layer; y⁺≈30 uses a wall model instead. |
| **Wall function** | An algebraic model that *estimates* the near-wall region instead of computing it. Cheap; harms drag accuracy. |
| **Boundary layer** | The thin, slow, high-shear air layer against the surface. Where friction drag comes from. |
| **RANS** | Reynolds-Averaged Navier–Stokes: solve for time-averaged flow, with turbulence modelled rather than computed. The industry workhorse. |
| **Spalart–Allmaras** | A one-equation turbulence model. Cheap and good for attached external flow; assumes turbulence from the leading edge. |
| **Transition** | Where laminar flow becomes turbulent. Modelling it matters at low Reynolds numbers; this run does not model it. |
| **Residual** | How badly the equations are still violated at each iteration. Dropping by orders of magnitude = converging. |
| **Order of magnitude** | Factor of 10. "Residuals dropped 7 orders" = a factor of 10⁷. |
| **Pseudo-time iteration** | Solver iteration count for a steady solution, **not** physical seconds. This run took 427. |
| **Converged** | The numbers stopped changing. **Not** the same as correct. |

## The mesh metrics

| Term | One line | Good |
|---|---|---|
| **Non-orthogonality** | How skewed cell faces are relative to the line between cell centres. High values degrade accuracy. | < 70 |
| **Skewness** | How distorted a cell is from its ideal shape. | < 4 |
| **Aspect ratio** | How stretched a cell is. Boundary-layer cells are deliberately stretched. | Large is normal near walls |

Measured here: non-orthogonality **51.6**, skewness **0.833**, aspect ratio **435** —
acceptable mesh, coarse mesh.

## The systems

| Term | One line |
|---|---|
| **DAFoam** | Open-source adjoint-enabled CFD/MDO built on OpenFOAM. Adjoints give gradients cheaply, which is what makes shape optimisation affordable. |
| **MDO Agent Deck** | DAFoam's agentic layer: narrow agents (airfoil/wing/aircraft), skills, and scenario workflows, exposed over MCP. Closed-source, evaluation licence. |
| **MCP** | Model Context Protocol — a standard way for an AI client to call external tools. One integration instead of N. |
| **Agent** | Here: a narrowly scoped domain (airfoil, wing, aircraft). Not a general chatbot. |
| **Skill** | A single capability, e.g. `generate-cfd-mesh`, with a fixed, validated input schema. |
| **Scenario** | A predefined multi-step workflow, e.g. "one skill, one run, with its prerequisite". |
| **Guardrail** | A check the system enforces on itself — `verify_workflow` refusing out-of-order calls. |
| **Adjoint** | A way to get the sensitivity of an output (drag) to thousands of inputs at roughly the cost of one extra solve. |

## The business side

| Term | One line |
|---|---|
| **TSFC** | Thrust-specific fuel consumption: fuel mass per unit thrust per second, kg/(N·s). |
| **Breguet range** | Idealised cruise range from fuel burned, speed and L/D: R = (V/(g·c_m))·(L/D)·ln(m_i/m_f). |
| **Why g appears** | TSFC is defined per unit *thrust* (a force), so converting to per-unit-weight brings in g. Mixing mass-based and weight-based conventions is the classic units bug. |
