# Examen_mySQL2_Javier_Suarez
# Integración de Datos Externos

El coworking ahora acepta reservas desde una plataforma externa (como Airbnb o Meetup). Debes integrar esos datos.

## Archivos

Ejecuta los scripts en este orden:

| #    | Archivo                    | Contenido                                                    |
| ---- | -------------------------- | ------------------------------------------------------------ |
| 1    | `1892-examen.sql`          | Tabla `ReservasExternas`, procedimiento `sp_importar_reserva_externa`, datos de prueba y verificación. |



## reservas externas

`1892-examen.sql` permite recibir reservas de plataformas externas y convertirlas en reservas internas.

1. La plataforma deposita la reserva en `ReservasExternas` (estado `Pendiente`).
2. Se llama al procedimiento con el id de esa fila:

El procedimiento:

- Bloquea la fila externa y el espacio para evitar importaciones simultáneas conflictivas.
- Valida que el espacio esté disponible, que la reserva sea del mismo día, que esté dentro del horario del espacio y que no se cruce con reservas vigentes.
- Busca al cliente por email y, si no existe, crea un **usuario temporal** (identificación `EXT-…`, fecha de nacimiento centinela `1900-01-01`).
- Crea la reserva interna como `Confirmada` y marca la externa como `Importada`.
- Si algo falla (incluidos los errores lanzados por triggers con `SIGNAL`), la marca como `Rechazada` con el motivo y devuelve `RECHAZADA: ...`.
- Si la reserva ya estaba importada, responde `IGNORADA` y no duplica nada.

