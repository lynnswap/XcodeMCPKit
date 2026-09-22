import Foundation

extension JSONRPC {
    package enum Wire {
        package enum EncodingFailure: Swift.Error, Equatable {
            case invalidJSONObject
        }

        package enum DecodingFailure: Swift.Error, Equatable {
            case messageWasNotObject
            case missingResult
        }

        package struct ErrorPayload: Sendable {
            package let code: Int
            package let message: String
            package let data: JSONValue?

            package init(code: Int, message: String, data: JSONValue? = nil) {
                self.code = code
                self.message = message
                self.data = data
            }
        }

        package static let version = "2.0"

        package static func requestObject(
            id: JSONRPC.ID,
            method: String,
            params: JSONValue? = nil
        ) -> [String: Any] {
            var object = notificationObject(method: method, params: params)
            object["id"] = id.value.foundationObject
            return object
        }

        package static func requestObject(
            id: Int64,
            method: String,
            params: JSONValue? = nil
        ) -> [String: Any] {
            requestObject(
                id: JSONRPC.ID(any: NSNumber(value: id))!,
                method: method,
                params: params
            )
        }

        package static func requestObject(
            id: String,
            method: String,
            params: JSONValue? = nil
        ) -> [String: Any] {
            requestObject(
                id: JSONRPC.ID(any: id)!,
                method: method,
                params: params
            )
        }

        package static func notificationObject(
            method: String,
            params: JSONValue? = nil
        ) -> [String: Any] {
            var object: [String: Any] = [
                "jsonrpc": version,
                "method": method,
            ]
            if let params {
                object["params"] = params.foundationObject
            }
            return object
        }

        package static func resultResponseObject(
            id: JSONRPC.ID,
            result: JSONValue
        ) -> [String: Any] {
            resultResponseObject(idValue: id.value, result: result)
        }

        package static func resultResponseObject(
            idValue: JSONValue?,
            result: JSONValue
        ) -> [String: Any] {
            [
                "jsonrpc": version,
                "id": idValue?.foundationObject ?? NSNull(),
                "result": result.foundationObject,
            ]
        }

        package static func errorObject(
            code: Int,
            message: String,
            data: JSONValue? = nil
        ) -> [String: Any] {
            var error: [String: Any] = [
                "code": code,
                "message": message,
            ]
            if let data {
                error["data"] = data.foundationObject
            }
            return error
        }

        package static func errorResponseObject(
            id: JSONRPC.ID?,
            code: Int,
            message: String,
            data: JSONValue? = nil
        ) -> [String: Any] {
            errorResponseObject(
                idValue: id?.value,
                error: ErrorPayload(code: code, message: message, data: data)
            )
        }

        package static func errorResponseObject(
            id: JSONRPC.ID,
            code: Int,
            message: String,
            data: JSONValue? = nil
        ) -> [String: Any] {
            errorResponseObject(
                idValue: id.value,
                error: ErrorPayload(code: code, message: message, data: data)
            )
        }

        package static func errorResponseObject(
            id: JSONRPC.ID?,
            error: ErrorPayload
        ) -> [String: Any] {
            errorResponseObject(idValue: id?.value, error: error)
        }

        package static func errorResponseObject(
            id: JSONRPC.ID,
            error: ErrorPayload
        ) -> [String: Any] {
            errorResponseObject(idValue: id.value, error: error)
        }

        package static func errorResponseObject(
            idValue: JSONValue?,
            error: ErrorPayload
        ) -> [String: Any] {
            [
                "jsonrpc": version,
                "id": idValue?.foundationObject ?? NSNull(),
                "error": errorObject(
                    code: error.code,
                    message: error.message,
                    data: error.data
                ),
            ]
        }

        package static func data(from payload: Any) throws -> Data {
            guard JSONSerialization.isValidJSONObject(payload) else {
                throw EncodingFailure.invalidJSONObject
            }
            return try JSONSerialization.data(withJSONObject: payload, options: [])
        }

        package static func object(fromData data: Data) throws -> [String: Any] {
            guard
                let object = try JSONSerialization.jsonObject(with: data, options: [])
                    as? [String: Any]
            else {
                throw DecodingFailure.messageWasNotObject
            }
            return object
        }

        package static func resultResponseData(
            id: JSONRPC.ID,
            result: JSONValue
        ) throws -> Data {
            try data(from: resultResponseObject(id: id, result: result))
        }

        package static func errorResponseData(
            id: JSONRPC.ID?,
            code: Int,
            message: String,
            data errorData: JSONValue? = nil
        ) throws -> Data {
            let object = errorResponseObject(
                id: id,
                code: code,
                message: message,
                data: errorData
            )
            return try data(from: object)
        }

        package static func errorResponseData(
            idValue: JSONValue?,
            code: Int,
            message: String,
            data errorData: JSONValue? = nil
        ) throws -> Data {
            let object = errorResponseObject(
                idValue: idValue,
                error: ErrorPayload(code: code, message: message, data: errorData)
            )
            return try data(from: object)
        }

        package static func objectByReplacingID(
            in object: [String: Any],
            with id: JSONRPC.ID
        ) -> [String: Any] {
            var rewritten = object
            rewritten["id"] = id.value.foundationObject
            return rewritten
        }

        package static func dataByReplacingID(
            in object: [String: Any],
            with id: JSONRPC.ID
        ) throws -> Data {
            try data(from: objectByReplacingID(in: object, with: id))
        }

        package static func resultValue(inResponseObject object: [String: Any]) -> JSONValue? {
            guard let resultAny = object["result"] else {
                return nil
            }
            return JSONValue(any: resultAny)
        }

        package static func resultValue(fromResponseData data: Data) throws -> JSONValue {
            let object = try object(fromData: data)
            guard let result = resultValue(inResponseObject: object) else {
                throw DecodingFailure.missingResult
            }
            return result
        }

        package static func errorPayload(inResponseObject object: [String: Any]) -> ErrorPayload? {
            guard let errorObject = object["error"] as? [String: Any] else {
                return nil
            }
            let code: Int
            if let number = errorObject["code"] as? NSNumber {
                code = number.intValue
            } else if let int = errorObject["code"] as? Int {
                code = int
            } else {
                code = -32000
            }
            let message = errorObject["message"] as? String ?? "upstream error"
            let data = errorObject["data"].flatMap(JSONValue.init(any:))
            return ErrorPayload(code: code, message: message, data: data)
        }

        package static func errorPayload(fromResponseData data: Data) -> ErrorPayload? {
            guard let object = try? object(fromData: data) else {
                return nil
            }
            return errorPayload(inResponseObject: object)
        }
    }
}
