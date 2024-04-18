package site.ycsb.db;

import org.apache.iceberg.*;
import org.apache.iceberg.catalog.Namespace;
import org.apache.iceberg.catalog.TableIdentifier;
import site.ycsb.ByteArrayByteIterator;
import site.ycsb.ByteIterator;
import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;
import java.util.*;
import static org.apache.iceberg.types.Types.NestedField.required;
import static org.apache.iceberg.types.Types.*;

public class CatalogClient extends DB {

  Catalog catalog;

  // Schema passed to create tables
  static final Schema SCHEMA =
      new Schema(
          required(3, "id", IntegerType.get(), "unique ID"),
          required(4, "data", StringType.get()));

  // This is the actual schema for the table, with column IDs reassigned
  static final Schema TABLE_SCHEMA =
      new Schema(
          required(1, "id", IntegerType.get(), "unique ID"),
          required(2, "data", StringType.get()));



  static final PartitionSpec SPEC = PartitionSpec.builderFor(SCHEMA).bucket("data", 16).build();


  private Optional<TableIdentifier> getIdentifierFromTableName(String tableName){
    return catalog.listTables(Namespace.empty()).stream()
        .filter(identifier -> identifier.name().equals(tableName))
        .findAny();
  }

  @Override
  public void init() throws DBException {
    // we should initialize Catalog here to some concrete implementation?
  }

//  @Override
//  public void cleanup() throws DBException {
//    System.out.println("cleanup");
//  }

  /**
   * Read a record from the database. Each field/value pair from the result will be stored in a HashMap.
   *
   * @param table The name of the table
   * @param key The record key of the record to read.
   * @param fields The list of fields to read, or null for all of them
   * @param result A HashMap of field/value pairs for the result
   * @return The result of the operation.
   */
  public Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result){
    // we don't care about reads?
    return Status.OK;
  }

  /**
   * Perform a range scan for a set of records in the database. Each field/value pair from the result will be stored
   * in a HashMap.
   *
   * @param table The name of the table
   * @param startkey The record key of the first record to read.
   * @param recordcount The number of records to read
   * @param fields The list of fields to read, or null for all of them
   * @param result A Vector of HashMaps, where each HashMap is a set field/value pairs for one record
   * @return The result of the operation.
   */
  @Override
  public Status scan(String table, String startkey, int recordcount, Set<String> fields,
                              Vector<HashMap<String, ByteIterator>> result){
    // we also don't care about reads...?
    return Status.OK;
  }

  /**
   * Update a record in the database. Any field/value pairs in the specified values HashMap will be written into the
   * record with the specified record key, overwriting any existing values with the same field name.
   *
   * @param table The name of the table
   * @param key The record key of the record to write.
   * @param values A HashMap of field/value pairs to update in the record
   * @return The result of the operation.
   */
  @Override
  public Status update(String table, String key, Map<String, ByteIterator> values){

    Optional<TableIdentifier> tblIdentifier = getIdentifierFromTableName(table);

    if(!tblIdentifier.isPresent()){
      return Status.BAD_REQUEST;
    }

//    var tx = catalog.newReplaceTableTransaction(
//        tblIdentifier.get(),
//        TABLE_SCHEMA,
//        false
//    );


    return Status.OK;
  }

  /**
   * Insert a record in the database. Any field/value pairs in the specified values HashMap will be written into the
   * record with the specified record key.
   *
   * @param table The name of the table
   * @param key The record key of the record to insert.
   * @param values A HashMap of field/value pairs to insert in the record
   * @return The result of the operation.
   */
  @Override
  public Status insert(String table, String key, Map<String, ByteIterator> values){

    var tblIdentifier = getIdentifierFromTableName(table);

    if(!tblIdentifier.isPresent()){
      return Status.BAD_REQUEST;
    }

//    var tx = catalog.newReplaceTableTransaction(
//        tblIdentifier.get(),
//        TABLE_SCHEMA,
//        false
//    );
//
//    AppendFiles appendFiles = tx.newAppend();
//    for (var entry : values.entrySet()){
//      var df = DataFiles.builder(SPEC)
//          .withPath(entry.getKey())
//          .withFileSizeInBytes(entry.getValue().bytesLeft())
//          .withPartitionPath("data_bucket=0")
//          .build();
//      appendFiles = appendFiles.appendFile(df); // this is weird?
//    }
//    appendFiles.commit();
//    tx.commitTransaction();

    return Status.OK;
  }

  /**
   * Delete a record from the database.
   *
   * @param table The name of the table
   * @param key The record key of the record to delete.
   * @return The result of the operation.
   */
  @Override
  public Status delete(String table, String key){

    Optional<TableIdentifier> tblIdentifier = getIdentifierFromTableName(table);

    if(!tblIdentifier.isPresent()){
      return Status.BAD_REQUEST;
    }

    if(catalog.dropTable(tblIdentifier.get())){
      return Status.OK;
    } else {
      return Status.ERROR;
    }

  }

}