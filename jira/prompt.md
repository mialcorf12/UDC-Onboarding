New Project: UDC Onboarding

Historia de Usuario
Título: Creación simultánea de Cuenta y Contacto mediante Web Service Apex con Validación de Entradas y Gestión de Errores

Como: Sistema Externo / Integrador

Quiero: Consumir un endpoint REST personalizado en Salesforce que valide estrictamente los datos de entrada de una Cuenta y un Contacto, y gestione de forma segura los errores DML

Para: Crear ambos registros de forma simultánea, vinculados entre sí, en una sola transacción y Garantizar que no se inserten datos incompletos y recibir códigos de error claros en caso de fallos en la creación o asociación de registros.

Descripción / Contexto
Actualmente, los sistemas externos (como Postman u otras API) necesitan optimizar el número de llamadas (API calls) a Salesforce. Se requiere un servicio web personalizado (Apex REST) que permita procesar la creación de un cliente completo (Empresa + Contacto) en un solo paso, en lugar de realizar dos llamadas independientes.

Criterios de Aceptación
1. Endpoint y Método HTTP
Método: POST

URL: /services/apexrest/UdcOnboardingService/

2. Estructura del Request (Payload JSON)
El servicio debe aceptar un JSON con la siguiente estructura mínima:

This is the payload we're going to use to send information.
JSON
{
  "onboard-type": "udesign.cloud",
  "is_parent" : "true",
  "org_name" : "uDesign Cloud India cc test",
  "org_type" : "Orthodontist",
  "org_status" : "uLab Account",
  "shipping_name" : "Smith Ortho 126",
  "shipping_address_1" : "111 Main St.\nBLDG 2\nSuite 33",
  "shipping_city" : "Fremont",
  "shipping_country" : "AU",
  "shipping_region" : "QLD",
  "shipping_zip" : "J5V3B2",
  "phone" : "5104099105",
  "billing_name" : "Dev CDN Ortho Clinic",
  "billing_address_1" : "111 Main St.\nBLDG 2\nSuite 33",
  "billing_city" : "Fremont",
  "billing_country" : "AU",
  "billing_region" : "QLD",
  "billing_zip" : "J5V3B2",
  "clinical_dev_spec" : "Jennifer Neuer-Wendel",
  "clinical_ed_spec" : "Robin Craycraft",
  "account_owner" : "Barbara Woodbury",
  "signature_required" : "false",
  "out_of_service_area" : "false",
  "user" : {
    "first_name" : "Test01",
    "last_name" : "Test",
    "email" : "activationusertest1@mailinator.com",
    "phone" : "5104099105",
    "mailing_name" : "docbraces Hatheway 125",
    "mailing_city" : "Fremont",
    "mailing_country" : "AU",
    "mailing_zipcode" : "J6Y3V2",
    "mailing_address_1" : "333 Central Ave",
    "mailing_state" : "QLD",
    "mailing_phone" : "5104099105"
  }
}

When using `user` in the payload, we're talking about a contact object.

3. Validación de Parámetros de Entrada (Antes de DML)
El código Apex debe validar el payload JSON antes de intentar cualquier operación en la base de datos. Si falla alguna validación, se debe rechazar la petición inmediatamente con un código HTTP 400 (Bad Request).

Campos Requeridos de Cuenta: accountName no puede estar vacío o nulo.

Campos Requeridos de Contacto: lastName no puede estar vacío o nulo (es obligatorio por estándar de Salesforce).

Validación de Formato (Email): Se debe verificar que el campo email (si se incluye) tenga un formato válido mediante una expresión regular básica en Apex, antes de enviarlo a Salesforce.

4. Gestión de Errores de Salesforce (DML y Asociación)
Toda la lógica de inserción debe estar envuelta en una estructura de control de excepciones (try-catch) para capturar fallos nativos de la plataforma:

Transaccionalidad Estricta (Rollback): Se debe definir un Savepoint al inicio de la transacción. Si la inserción del Contacto falla (por ejemplo, por una regla de validación de negocio, un trigger de terceros o un fallo de duplicados), se debe ejecutar un Database.rollback() para deshacer la creación de la Cuenta. No deben quedar cuentas huérfanas.

Error en Creación de Cuenta: Si la Cuenta falla al insertarse, el flujo debe saltar directamente al bloque de captura de errores, impidiendo que se procese el contacto.

Error en Asociación: El ID de la Cuenta creada debe asignarse explícitamente al campo AccountId del Contacto. Cualquier fallo en esta asignación o en los permisos de nivel de registro (Row-Level Security) debe ser capturado.

5. Estructuras de Respuesta ((Manejo de Errores y Éxito)

Respuesta Exitosa (Código HTTP 201 / 200): Debe devolver los IDs de los registros creados.
JSON
{
  "success": true,
  "message": "Account and Contact created successfully.",
  "accountId": "001XXXXXXXXXXXXXXX",
  "contactId": "003XXXXXXXXXXXXXXX"
}

Error de Validación de Entrada (HTTP 400 - Bad Request): de forma individual por campo requerido.
JSON
{
  "success": false,
  "errorCode": "INVALID_INPUT",
  "message": "Validation failed: 'accountName' and 'lastName' are required fields. 'email' must have a valid format."
}

Error de Ejecución/DML en Salesforce (HTTP 500 - Internal Server Error):
Si Salesforce rechaza el registro debido a un Trigger, Process Builder, Regla de Validación o Duplicate Rule:
JSON
{
  "success": false,
  "errorCode": "SALESFORCE_DML_ERROR",
  "message": "The transaction was rolled back. Original Salesforce error: [FIELD_CUSTOM_VALIDATION_EXCEPTION] El correo electrónico ya está registrado en otro contacto activo."
}


5. Pruebas Unitarias (Test Class)
El endpoint debe requerir autenticación estándar de Salesforce (OAuth 2.0 / Bearer Token) para poder ser consumido desde Postman o cualquier API externa.

Se debe incluir la clase de prueba (Test Class) con una cobertura mínima del 80%, validando escenarios de éxito y escenarios de error (faiures).

La clase de prueba debe cubrir los nuevos escenarios con un esquema de aserciones (System.assertEquals):

Test de Éxito: Flujo limpio donde ambos registros se crean.

Test de Error de Validación: Envío de JSON sin lastName para validar el HTTP 400.

Test de Fallo DML (Rollback): Forzar un fallo en el contacto (por ejemplo, enviando un apellido que dispare una regla de validación deliberadamente) y verificar mediante un Query que la Cuenta tampoco se guardó en la base de datos.

Tips de Arquitecto (Para la implementación)
Validación Temprana: Valida que los campos requeridos no vengan nulos o vacíos en el código Apex antes de intentar hacer el insert, para ahorrar tiempo de procesamiento.
Manejo de Excepciones: Utiliza un bloque try-catch capturando DMLException para formatear los errores nativos de Salesforce en una respuesta JSON amigable para el sistema externo.

💡 Tip Técnico para el Desarrollador
Para mapear los errores nativos de Salesforce de forma limpia en el JSON de respuesta, se recomienda usar e.getDmlMessage(0) en lugar de e.getMessage(). Esto extraerá únicamente el mensaje de error de cara al usuario (como el de una Regla de Validación) omitiendo los detalles técnicos internos del stack trace de Apex que el sistema externo no necesita conocer.